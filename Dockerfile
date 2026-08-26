# Hidden Agenda game + player image. ONE image, TWO entrypoints:
#   /bin/hidden-agenda         - the game server (default)
#   /bin/hidden-agenda-player  - the thin prompt-carrying seat
# The policy set is env-switched inside this same image (PLAYER_PROMPT vs
# PLAYER_SCRIPTED), which is what keeps a champion and a scripted filler
# byte-identical apart from their environment.
FROM debian:bookworm-slim AS build

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    git && \
  rm -rf /var/lib/apt/lists/*

RUN if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-X64; \
  elif [ "$(dpkg --print-architecture)" = "arm64" ]; then \
    curl -fsSL \
      -o /usr/local/bin/nimby \
https://github.com/treeform/nimby/releases/download/0.1.26/nimby-Linux-ARM64; \
  else \
    echo "unsupported arch: $(dpkg --print-architecture)" && exit 1; \
  fi && \
  chmod +x /usr/local/bin/nimby && \
  nimby use 2.2.4

ENV PATH="/root/.nimby/nim/bin:$PATH"

WORKDIR /workspace/hidden_agenda
COPY nimby.lock .
RUN nimby --global sync nimby.lock

COPY . .
# A committed nim.cfg would pin the author's machine package paths; regenerate
# it from THIS container's synced package tree. The binaries take the hyphenated
# slug (`-o:`) while the Nim modules keep the underscore.
RUN rm -f nim.cfg && \
  for pkg in /root/.nimby/pkgs/*; do \
    if [ -d "$pkg/src" ]; then echo "--path:\"$pkg/src\"" >> nim.cfg; \
    else echo "--path:\"$pkg\"" >> nim.cfg; fi; \
  done && \
  echo '--path:"src"' >> nim.cfg && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/hidden-agenda-nimcache --out:hidden-agenda \
    src/hidden_agenda.nim && \
  nim c -d:release -d:useMalloc --opt:speed --stackTrace:on \
    --nimcache:/tmp/hidden-agenda-player-nimcache --out:hidden-agenda-player \
    src/hidden_agenda_player.nim

# Run image.
FROM debian:bookworm-slim

RUN apt-get update && \
  apt-get install -y --no-install-recommends ca-certificates libcurl4 && \
  rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/hidden_agenda
COPY --from=build /workspace/hidden_agenda/hidden-agenda /bin/hidden-agenda
COPY --from=build /workspace/hidden_agenda/hidden-agenda-player \
  /bin/hidden-agenda-player
COPY --from=build /workspace/hidden_agenda/data ./data
COPY --from=build /workspace/hidden_agenda/client ./client

CMD ["/bin/hidden-agenda"]
