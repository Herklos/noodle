# The Noodle Push server for Cloudflare Containers, which run linux/amd64.
# A fully static musl binary from the Swift Static Linux SDK, on distroless/static: no shell, no libc,
# only CA certificates for APNs. The SDK must match the toolchain's exact release.
# Both images are pinned by the digest of their multi-arch index, looked up from the registries on
# 2026-10-21; the tags are kept for reading. Bump tag and digest together.

# swift:6.4.1-noble (Docker Hub, library/swift)
FROM --platform=linux/amd64 swift:6.4.1-noble@sha256:19cbe56bdaec1918f7cf5fdeba42b9bd55bdd8a6149c9990d0e0e3a89a127d63 AS build
ARG SDK_URL=https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
ARG SDK_CHECKSUM=cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c
RUN swift sdk install "$SDK_URL" --checksum "$SDK_CHECKSUM"
WORKDIR /src
# The test targets come along because the manifest names them; only NoodlePush is built.
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
# --force-resolved-versions builds exactly what Package.resolved pins, and fails instead of resolving anew.
RUN swift build -c release --product NoodlePush --swift-sdk x86_64-swift-linux-musl --force-resolved-versions \
    && cp "$(swift build -c release --swift-sdk x86_64-swift-linux-musl --force-resolved-versions --show-bin-path)/NoodlePush" /NoodlePush

# gcr.io/distroless/static-debian12:nonroot
FROM --platform=linux/amd64 gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
COPY --from=build /NoodlePush /usr/local/bin/NoodlePush
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/NoodlePush"]
