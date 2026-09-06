# syntax=docker/dockerfile:1
ARG RUBY_VERSION=3.4.10
ARG BUNDLER_VERSION=4.0.18
ARG FASTLANE_VERSION=2.234.0
ARG MISE_VERSION=v2026.8.2

########################################
# Stage 1: deps - libs de sistema + mise
########################################
FROM diogo0liveira/android-37-slim:1.0.0 AS deps

# A imagem base termina como `USER android` (não-root). Este estágio
# precisa de root para apt-get, para instalar o mise em /opt e para
# compilar o Ruby. É revertido para não-root no final.
USER root

ARG MISE_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MISE_DATA_DIR=/opt/mise \
    MISE_CONFIG_DIR=/opt/mise \
    MISE_INSTALL_PATH=/usr/local/bin/mise \
    MISE_YES=1 \
    PATH="/opt/mise/shims:/opt/mise/bin:/usr/local/bin:${PATH}"

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        curl \
        git \
        build-essential \
        libssl-dev \
        libreadline-dev \
        zlib1g-dev \
        libyaml-dev \
        libffi-dev \
        libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://mise.run | MISE_VERSION=${MISE_VERSION} sh

########################################
# Stage 2: ruby - instala o Ruby via mise
# (cache: só invalida se RUBY_VERSION mudar)
########################################
FROM deps AS ruby
ARG RUBY_VERSION

# --disable-install-doc: ruby-build (usado internamente pelo mise) repassa
# essa opção ao `./configure` do Ruby, pulando a geração/instalação de rdoc/ri
ENV RUBY_CONFIGURE_OPTS="--disable-install-doc"

RUN --mount=type=cache,target=/opt/mise/cache,sharing=locked \
    mise use --global ruby@${RUBY_VERSION} \
    && mise install \
    && mise reshim \
    && ruby -v

########################################
# Stage 3: fastlane - Bundler + Fastlane como gems de sistema
# (cache: só invalida se BUNDLER_VERSION/FASTLANE_VERSION mudarem;
# não depende de nenhum Gemfile de projeto)
########################################
FROM ruby AS fastlane
ARG BUNDLER_VERSION
ARG FASTLANE_VERSION

# Bundler: para que cada projeto Android possa rodar `bundle install`
# com o PRÓPRIO Gemfile/Gemfile.lock (e seus próprios plugins) direto
# no workflow, sem depender de nada pré-fixado nesta imagem.
#
# Fastlane: instalado global (fora de um Gemfile) para já vir pronto
# de fábrica em `fastlane <lane>`, mesmo em projetos sem Gemfile.
RUN gem install bundler -v ${BUNDLER_VERSION} --no-document \
    && gem install fastlane -v ${FASTLANE_VERSION} --no-document \
    && mise reshim \
    && fastlane --version \
    && bundle --version

########################################
# Stage 4: final - imagem de runtime
########################################
FROM diogo0liveira/android-37-slim:1.0.0 AS final
ARG RUBY_VERSION
ARG BUNDLER_VERSION
ARG FASTLANE_VERSION

# A imagem base termina como `USER android`. Voltamos para root aqui
# porque: (a) precisamos instalar libs via apt e copiar para /opt como
# root, e (b) para o uso como container de job do GitHub Actions, root
# é o que evita "permission denied" em $GITHUB_OUTPUT/workspace (ver
# comentário abaixo). Se for usar esta imagem SOMENTE fora de CI,
# pode-se reintroduzir `USER android` no fim do estágio.
USER root

LABEL maintainer="Diogo Oliveira <diogo0liveira@hotmail.com>" \
      org.opencontainers.image.title="Android SDK 37 Docker — Stretch" \
      org.opencontainers.image.description="Imagem Docker para compilação e publicação com Fastlane no Android 37" \
      org.opencontainers.image.source="https://github.com/diogo0liveira/docker-android-37-stretch" \
      org.opencontainers.image.base.name="diogo0liveira/android-37-slim:1.0.0" \
      dev.sigstore.cosign.signed="true" \
      dev.diogo0liveira.ruby.version="${RUBY_VERSION}" \
      dev.diogo0liveira.bundler.version="${BUNDLER_VERSION}" \
      dev.diogo0liveira.fastlane.version="${FASTLANE_VERSION}"


ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH="/opt/mise/installs/ruby/${RUBY_VERSION}/bin:/usr/local/bin:${PATH}" \
    FASTLANE_SKIP_UPDATE_CHECK=1 \
    FASTLANE_HIDE_CHANGELOG=1 \
    FASTLANE_DISABLE_COLORS=1

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
        git \
        openssh-client \
        libssl3 \
        libreadline8 \
        zlib1g \
        libyaml-0-2 \
        libffi8 \
        libgmp10 \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system --add safe.directory '*' \
    && { \
         echo 'install: --no-document'; \
         echo 'update: --no-document'; \
       } >> /etc/gemrc

# Traz só a instalação de Ruby já compilada (com Bundler e Fastlane como
# gems de sistema dentro dela) do stage "fastlane".
COPY --from=fastlane /opt/mise/installs/ruby/${RUBY_VERSION} /opt/mise/installs/ruby/${RUBY_VERSION}

RUN ruby -v \
    && bundle --version \
    && fastlane --version

USER android
CMD ["/bin/bash"]