ARG RUNNER_VERSION=2.334.0
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# Switch to root to install packages
USER root

# Install make, build tools, and dependencies for native Node.js modules (canvas, etc.)
RUN apt-get update && apt-get install -y \
    make \
    build-essential \
    pkg-config \
    python3 \
    # Canvas/image processing dependencies
    libcairo2-dev \
    libpango1.0-dev \
    libjpeg-dev \
    libgif-dev \
    librsvg2-dev \
    libpixman-1-dev \
    # Additional useful tools
    git \
    curl \
    # Java runtime for the SAP AMS DCL->DCN compiler. @sap/ams-dev's `compile-dcl`
    # (run both by the CDS test boot and by scripts/compile-ams-dcn-for-tests.mjs)
    # shells out to a bundled `dcl.jar`, gated on `java --version`. Without a JRE on
    # PATH the AMS authorization bundle never compiles ("no authorization data loaded").
    openjdk-17-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Fail the build early if Java isn't on PATH (the SAP AMS dcl-compiler depends on it).
RUN java -version

# Install Cloud Foundry CLI
RUN curl -L "https://packages.cloudfoundry.org/stable?release=linux64-binary&version=v8&source=github" | tar -zx -C /usr/local/bin \
    && cf --version

# Switch back to runner user
USER runner
