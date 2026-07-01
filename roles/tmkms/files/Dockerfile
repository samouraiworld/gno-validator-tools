# NOTE: kept byte-identical to tmkms-lab/tmkms/Dockerfile (and vice-versa).
# If you change one, change the other.
# tmkms signer image (softsign backend).
# 0.15.0 has no default features, so softsign must be requested explicitly.
# Built on Debian so the binary links the same glibc family as the gnoland image.
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
