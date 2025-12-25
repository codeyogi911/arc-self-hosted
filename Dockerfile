FROM ghcr.io/actions/actions-runner:latest

# Switch to root to install packages
USER root

# Install make and dependencies
RUN apt-get update && apt-get install -y \
    make \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Install Cloud Foundry CLI
RUN curl -L "https://packages.cloudfoundry.org/stable?release=linux64-binary&version=v8&source=github" | tar -zx -C /usr/local/bin \
    && cf --version

# Switch back to runner user
USER runner

