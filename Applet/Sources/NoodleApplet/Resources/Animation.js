// Injected inside a closure with an explicit, host-selected `synthetic` boolean.
// The page's clock. It is the browser's own until something takes it over: a test clock
// (`synthetic`) moves animation frames and performance.now only when stepped, and a recording
// films the page, moving its clock on exactly one frame at a time, so every frame of the video
// shows the page at precisely that frame's time. While filmed, animation frames, performance.now,
// Date, timers, and CSS and Web Animations all follow that clock.
const nativeVisibility = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState').get;
const nativeNow = performance.now.bind(performance);
const nativeRAF = window.requestAnimationFrame.bind(window);
const NativeDate = Date, nativeDateNow = Date.now.bind(Date);
const nativeTimeout = window.setTimeout.bind(window), nativeClearTimeout = window.clearTimeout.bind(window);
const nativeInterval = window.setInterval.bind(window), nativeClearInterval = window.clearInterval.bind(window);
const send = body => window.webkit.messageHandlers.noodle.postMessage(body);
let time = 0, nextID = 0, frameCount = 0, lastTimestamp = null, lastReport = -Infinity;
// How far the page's clock trails the browser's since a recording, which can fall behind real
// time, gave it back: performance.now carries on from where the film left it, never backwards.
let behind = 0;
// While filmed: how long a frame lasts, how far Date is from the page's clock, and the
// animations the film holds and moves on itself.
let film = null;
const now = () => synthetic || film ? time : nativeNow() - behind;
const pending = new Map();
const state = () => ({
  readyState: document.readyState,
  visibilityState: document.visibilityState,
  nativeVisibilityState: nativeVisibility.call(document),
  synthetic,
  animationFrameCount: frameCount,
  lastAnimationFrameTimestamp: lastTimestamp
});
const report = () => send({operation: 'rendering', state: state()}).catch(() => {});
const observed = timestamp => {
  if (lastTimestamp !== timestamp) { frameCount++; lastTimestamp = timestamp; }
  if (!synthetic && nativeNow() - lastReport >= 500) {
    lastReport = nativeNow();
    report();
  }
};
// A callback that throws is reported as the browser would, and the others still run.
const fail = error => synthetic
  ? send({operation:'log',level:'error',text:String(error) + '\n' + (error?.stack || '')}).catch(() => {})
  : reportError(error);
if (synthetic) {
  Object.defineProperties(document, {
    hidden: {get: () => false}, visibilityState: {get: () => 'visible'}
  });
}
Object.defineProperty(performance, 'now', {value: function now() { return synthetic || film ? time : nativeNow() - behind; }});

// Animation frames. Callbacks requested meanwhile wait for the next frame; a later callback
// cancelled during this one does not run.
const runFrame = async timestamp => {
  for (const id of [...pending.keys()]) {
    const callback = pending.get(id);
    if (!callback) continue;
    pending.delete(id);
    observed(timestamp);
    try { callback(timestamp); } catch (error) { fail(error); }
    await Promise.resolve();
  }
};
// On the browser's clock the frames come from the browser, one request at a time.
let ticking = false;
const tick = timestamp => {
  ticking = false;
  if (!synthetic && !film) runFrame(timestamp - behind);
};
const request = () => {
  if (ticking || synthetic || film || !pending.size) return;
  ticking = true;
  nativeRAF(tick);
};
window.requestAnimationFrame = callback => {
  if (typeof callback !== 'function') throw new TypeError('Animation callback must be a function');
  const id = ++nextID;
  pending.set(id, callback);
  request();
  return id;
};
window.cancelAnimationFrame = id => { pending.delete(Number(id)); };

// Date reads the film's clock while filmed, and the real time otherwise.
const dateNow = () => film ? Math.floor(time + film.date) : nativeDateNow();
function PageDate(...values) {
  if (!new.target) return new NativeDate(dateNow()).toString();
  return Reflect.construct(NativeDate, values.length ? values : [dateNow()], new.target);
}
Object.defineProperties(PageDate, {
  prototype: {value: NativeDate.prototype},
  now: {value: function now() { return dateNow(); }, writable: true, configurable: true},
  parse: {value: NativeDate.parse, writable: true, configurable: true},
  UTC: {value: NativeDate.UTC, writable: true, configurable: true},
  length: {value: NativeDate.length},
  name: {value: 'Date'},
});
Object.defineProperty(NativeDate.prototype, 'constructor', {value: PageDate, writable: true, configurable: true});
window.Date = PageDate;

// Timers. Each is kept with when it is due on the page's clock, so a recording can take over the
// ones already waiting, fire them as its frames pass that time and hand them back afterwards.
const timers = new Map();
let nextTimer = 0, nesting = 0;
const arm = (id, timer, wait) => {
  timer.interval = timer.repeat && wait === timer.delay;
  timer.handle = (timer.interval ? nativeInterval : nativeTimeout)(() => fire(id), wait);
};
const disarm = timer => {
  if (timer.handle !== null) (timer.interval ? nativeClearInterval : nativeClearTimeout)(timer.handle);
  timer.handle = null;
};
const fire = id => {
  const timer = timers.get(id);
  if (!timer) return;
  if (!timer.repeat) timers.delete(id);
  // Browsers wait at least 4 ms between repeats; a film that did not would never finish its frame.
  else if (film) timer.due += Math.max(timer.delay, 4);
  else {
    timer.due = now() + timer.delay;
    // One handed back part way through its wait repeats natively from now on.
    if (!timer.interval) arm(id, timer, timer.delay);
  }
  const outer = nesting;
  nesting = timer.nesting;
  try {
    if (typeof timer.callback === 'function') timer.callback.apply(window, timer.args);
    else (0, eval)(String(timer.callback));
  } catch (error) { reportError(error); }
  finally { nesting = outer; }
};
const schedule = (repeat, callback, delay, args) => {
  const id = ++nextTimer;
  let wait = Math.max(0, Number(delay) || 0);
  const timer = {callback, args, delay: wait, repeat, nesting: nesting + 1, due: 0, handle: null, interval: false};
  // As browsers do, timers set from timers nested deeper than five wait at least 4 ms.
  if (film && timer.nesting > 5 && wait < 4) wait = 4;
  timer.due = now() + wait;
  timers.set(id, timer);
  if (!film) arm(id, timer, wait);
  return id;
};
const clear = id => {
  const timer = timers.get(Number(id));
  if (!timer) return;
  disarm(timer);
  timers.delete(Number(id));
};
window.setTimeout = function setTimeout(callback, delay, ...args) { return schedule(false, callback, delay, args); };
window.setInterval = function setInterval(callback, delay, ...args) { return schedule(true, callback, delay, args); };
window.clearTimeout = function clearTimeout(id) { clear(id); };
window.clearInterval = function clearInterval(id) { clear(id); };
// Fires the timers due by `target` in the order they fall due, each at its own time.
const advanceTimers = async target => {
  // A page that keeps setting timers due at once still lets the frame end.
  for (let fired = 0; fired < 10000; fired++) {
    let id = null, next = null;
    for (const [key, timer] of timers) {
      if (timer.due <= target && (!next || timer.due < next.due)) { id = key; next = timer; }
    }
    if (!next) return;
    time = Math.max(time, next.due);
    fire(id);
    await Promise.resolve();
  }
};

// CSS and Web Animations run on the browser's own timeline, so while filmed each one is paused
// and moved on by the film a frame at a time. One that reaches its end is finished, so its
// events still fire; the rest play on from where the film left them.
const hold = () => {
  for (const animation of document.getAnimations()) {
    if (animation.playState !== 'running') continue;
    try {
      const at = animation.currentTime ?? 0;
      animation.pause();
      // Setting the time completes the pause at once rather than on the browser's next frame.
      animation.currentTime = at;
      film.animations.add(animation);
    } catch {}
  }
};
const advanceAnimations = () => {
  for (const animation of film.animations) {
    // The page played, cancelled or finished it itself; one playing again is held anew.
    if (animation.playState !== 'paused') { film.animations.delete(animation); continue; }
    try {
      const rate = animation.playbackRate, at = (animation.currentTime ?? 0) + film.step * rate;
      const end = animation.effect?.getComputedTiming().endTime ?? Infinity;
      if (rate > 0 ? at >= end : rate < 0 && at <= 0) {
        film.animations.delete(animation);
        animation.finish();
      } else animation.currentTime = at;
    } catch { film.animations.delete(animation); }
  }
};

// The film: begin puts the page on its clock where the browser's is now, frame moves it on one
// frame, and end gives the page back to the browser's clock without a jump.
const begin = async framesPerSecond => {
  if (synthetic) throw new Error('A page on a test clock is recorded as it runs.');
  if (!(framesPerSecond > 0 && framesPerSecond <= 240)) throw new RangeError('Use 1–240 frames a second.');
  if (film) return false;
  time = now();
  film = {step: 1000 / framesPerSecond, date: nativeDateNow() - time, animations: new Set()};
  for (const timer of timers.values()) {
    disarm(timer);
    // A page out of sight has its timers held back; one overdue fires once, as it would natively.
    timer.due = Math.max(timer.due, time);
  }
  hold();
  // The first frame shows the page at this very time too.
  await advanceTimers(time);
  await runFrame(time);
  hold();
  return true;
};
const frame = async () => {
  if (!film) return false;
  const target = time + film.step;
  advanceAnimations();
  await advanceTimers(target);
  time = target;
  await runFrame(time);
  // Animations started during this frame are held from their first frame.
  hold();
  return true;
};
const end = () => {
  if (!film) return false;
  const held = film.animations;
  behind = nativeNow() - time;
  film = null;
  for (const animation of held) {
    try { if (animation.playState === 'paused') animation.play(); } catch {}
  }
  for (const [id, timer] of timers) arm(id, timer, Math.max(0, timer.due - now()));
  request();
  return true;
};

let stepping = false;
const step = async (frames = 1) => {
  if (!synthetic) throw new Error('Open with --mode headless --test-clock before stepping.');
  if (!Number.isInteger(frames) || frames < 1 || frames > 600) throw new RangeError('Use 1–600 frames.');
  if (stepping) throw new Error('A frame step is already in progress.');
  stepping = true;
  try {
    for (let frame = 0; frame < frames; frame++) {
      time += 1000 / 60;
      await runFrame(time);
    }
    await report();
    return {synthetic:true, frames, timeMilliseconds:time, pendingAnimationFrames:pending.size, ...state()};
  } finally { stepping = false; }
};
Object.defineProperty(window, '__noodletAnimation', {
  value: Object.freeze({state, step, film: Object.freeze({begin, frame, end})})
});
document.addEventListener('readystatechange', report);
document.addEventListener('visibilitychange', report);
report();
