# NOTE: kept byte-identical to roles/tmkms/files/Dockerfile (and vice-versa).
# If you change one, change the other.
# tmkms signer image (softsign). Built on VM2.
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
