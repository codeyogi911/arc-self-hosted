FROM ghcr.io/actions/actions-runner:latest

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
    && rm -rf /var/lib/apt/lists/*

# Install Cloud Foundry CLI
RUN curl -L "https://packages.cloudfoundry.org/stable?release=linux64-binary&version=v8&source=github" | tar -zx -C /usr/local/bin \
    && cf --version

# Switch back to runner user
USER runner

