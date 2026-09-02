ARG RUNNER_VERSION=latest
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# The upstream ARC image deliberately contains only the runner and its hooks.
# mymediset_cloud compiles Canvas dependencies and invokes the SAP AMS Java
# compiler during tests, so keep only those shared CI prerequisites here.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        python3 \
        libcairo2-dev \
        libpango1.0-dev \
        libjpeg-dev \
        libgif-dev \
        librsvg2-dev \
        libpixman-1-dev \
        openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

RUN java -version

USER runner
