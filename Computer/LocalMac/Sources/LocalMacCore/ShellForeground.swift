import Darwin

/// Whether a shell is busy, for closing agents' shells left idle at their prompt.
public enum LocalMacShellForeground {
    /// Whether a command holds the foreground of the terminal whose controlling side is `master`,
    /// rather than `shell`, which leads its own session and process group, waiting at its prompt.
    /// A job-control shell gives each command it runs in the foreground a process group of its
    /// own. Nil when the terminal cannot say.
    public static func runsCommand(master: Int32, shell: pid_t) -> Bool? {
        let group = tcgetpgrp(master)
        guard group > 0, shell > 0 else { return nil }
        return group != shell
    }
}
