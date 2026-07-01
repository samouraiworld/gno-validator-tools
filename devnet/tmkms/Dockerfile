# tmkms signer image (softsign backend) for the devnet sidecar.
# Compiled from source: 0.15.0 has no default features, so softsign must be
# requested explicitly. Built on Debian so the binary links the same glibc as
# the gnoland image it talks to.
FROM rust:slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      pkg-config libssl-dev build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN cargo install tmkms --version 0.15.0 --features softsign --locked

FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/cargo/bin/tmkms /usr/local/bin/tmkms
ENTRYPOINT ["tmkms"]
