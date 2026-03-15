# syntax=docker/dockerfile:1
# check=error=true

FROM ubuntu:latest AS core

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        curl \
        gpg \
        libc6-dev \
        software-properties-common \
        sudo \
        wget \
        xz-utils && \
    apt-get clean

FROM core AS tools

# Install git from its official ppa.
RUN add-apt-repository -y ppa:git-core/ppa && \
    apt-get update && apt-get install -y git
RUN git --version && which git

# Install jq from its official image.
COPY --from=ghcr.io/jqlang/jq:latest /jq /usr/local/bin/jq
RUN jq --version && which jq

# Install 1Password CLI from its official image.
COPY --from=1password/op:latest /usr/local/bin/op /usr/local/bin/op
RUN op --version && which op

# Install GitLab CLI from its official image.
COPY --from=gitlab/glab:latest /usr/bin/glab /usr/local/bin/glab
RUN glab --version && which glab

# Install GitHub CLI from its official repository.
RUN apt-get update && \
    mkdir -p -m 755 /etc/apt/keyrings /etc/apt/sources.list.d && \
    wget -nv -O /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" >/etc/apt/sources.list.d/github-cli.list && \
    apt-get update && \
    apt-get install -y gh
RUN gh --version && which gh

# Install uv and uvx system-wide from the official image.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/
RUN uv --version && which uv
RUN uvx --version && which uvx

FROM tools AS dev-user

COPY etc/wsl.conf /opt/dotfiles/etc/wsl.conf

RUN useradd --create-home --home-dir /home/dev --shell /bin/bash --user-group --groups sudo dev && \
    printf 'dev ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/90-dev && \
    chmod 0440 /etc/sudoers.d/90-dev && \
    install -d -o dev -g dev /opt/dotfiles /home/dev && \
    cp /opt/dotfiles/etc/wsl.conf /etc/wsl.conf

USER dev
ENV HOME=/home/dev
ENV PATH=/home/dev/.local/bin:${PATH}

RUN echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

WORKDIR /opt/dotfiles

FROM dev-user AS py

RUN uv python install --default
RUN uv python update-shell
RUN uv python list

FROM py AS rs

COPY --chown=dev:dev manifests/crates.txt /opt/dotfiles/manifests/crates.txt
COPY --chown=dev:dev llvm-release.jq /opt/dotfiles/llvm-release.jq

RUN mkdir -p "$HOME/.cargo" && \
    curl -fsSL https://sh.rustup.rs | \
        sh -s -- -y -v --default-toolchain="stable" --component="rust-analyzer,llvm-tools,rust-src,rust-analysis,rust-docs"
RUN echo '. "$HOME/.cargo/env"' >> "$HOME/.bashrc"

RUN /bin/bash -lc 'case "$(uname -m)" in \
        x86_64|amd64) asset_suffix="Linux-X64.tar.xz" ;; \
        aarch64|arm64) asset_suffix="Linux-ARM64.tar.xz" ;; \
        *) printf "unsupported architecture for LLVM release archive: %s\\n" "$(uname -m)" >&2; exit 1 ;; \
    esac && \
    release_info="$(curl -fsSL https://api.github.com/repos/llvm/llvm-project/releases/latest | jq -r --arg suffix "$asset_suffix" -f /opt/dotfiles/llvm-release.jq)" && \
    test -n "$release_info" && \
    printf "%s\\n" "$release_info" > /tmp/llvm-release.tsv'

RUN /bin/bash -lc 'IFS="$(printf "\\t")" read -r release_tag package_name package_url bundle_url < /tmp/llvm-release.tsv && \
    version_dir="/opt/llvm/$release_tag" && \
    if [ ! -x "$version_dir/bin/ld.lld" ]; then \
        tmpdir="$(mktemp -d)" && \
        archive="$tmpdir/$package_name" && \
        bundle="$archive.jsonl" && \
        curl -fsSL -o "$archive" "$package_url" && \
        curl -fsSL -o "$bundle" "$bundle_url" && \
        gh attestation verify --repo llvm/llvm-project "$archive" --bundle "$bundle" && \
        tar -C "$tmpdir" -xf "$archive" && \
        extracted_root="$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -n 1)" && \
        test -n "$extracted_root" && \
        sudo mkdir -p /opt/llvm && \
        sudo rm -rf "$version_dir" && \
        sudo mv "$extracted_root" "$version_dir" && \
        rm -rf "$tmpdir"; \
    fi && \
    sudo ln -sfn "$version_dir" /opt/llvm/current && \
    rm -f /tmp/llvm-release.tsv'

RUN printf "%s\n" \
        "[target.\"cfg(target_os = \\\"linux\\\")\"]" \
        "linker = \"/opt/llvm/current/bin/clang\"" \
        "rustflags = [\"-C\", \"link-arg=-fuse-ld=/opt/llvm/current/bin/ld.lld\"]" \
        > "$HOME/.cargo/config.toml"

RUN . "$HOME/.cargo/env" && cargo install --locked coreutils \
    ripgrep \
    cargo-nextest \
    ast-grep \
    cargo-depgraph \
    cargo-llvm-cov \
    cargo-mutants \
    mergiraf \
    wild-linker \
    xan

FROM rs AS npm

SHELL ["/bin/bash", "-lc"]

RUN export NVM_DIR="$HOME/.nvm" && \
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash && \
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" && \
    [ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion" && \
    nvm install --latest-npm && \
    npm install -g @openai/codex

RUN echo 'export NVM_DIR="$HOME/.nvm"' >> "$HOME/.bashrc" && \
    echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' >> "$HOME/.bashrc" && \
    echo '[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"' >> "$HOME/.bashrc"

FROM npm AS final

USER root
RUN curl -sS https://starship.rs/install.sh | sh -s -- -y
RUN echo 'eval "$(starship init bash)"' >> /home/dev/.bashrc

RUN apt-get clean && apt-get autoremove && \
    rm -rf /tmp/* /var/tmp/*

USER dev
COPY --chown=dev:dev .bash_aliases /home/dev/.bash_aliases
COPY --chown=dev:dev .gitconfig /home/dev/.gitconfig

RUN echo '[ -f "$HOME/.bash_aliases" ] && . "$HOME/.bash_aliases"' >> /home/dev/.bashrc

CMD ["/bin/bash"]
