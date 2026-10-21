# The Noodle Push server for Cloudflare Containers, which run linux/amd64.
# A fully static musl binary from the Swift Static Linux SDK, on distroless/static: no shell, no libc,
# only CA certificates for APNs. The SDK must match the toolchain's exact release.

FROM --platform=linux/amd64 swift:6.4.1-noble AS build
ARG SDK_URL=https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
ARG SDK_CHECKSUM=cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c
RUN swift sdk install "$SDK_URL" --checksum "$SDK_CHECKSUM"
WORKDIR /src
# The test targets come along because the manifest names them; only NoodlePush is built.
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product NoodlePush --swift-sdk x86_64-swift-linux-musl \
    && cp "$(swift build -c release --swift-sdk x86_64-swift-linux-musl --show-bin-path)/NoodlePush" /NoodlePush

FROM --platform=linux/amd64 gcr.io/distroless/static-debian12:nonroot
COPY --from=build /NoodlePush /usr/local/bin/NoodlePush
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/NoodlePush"]
