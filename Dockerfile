FROM debian:buster-slim

ENV Q2_EXECUTEABLE="r1q2ded-old"
ENV Q2_GAMEDIR="arena"
ENV Q2_IP="localhost"
ENV Q2_PORT="27910"

RUN echo 'debconf debconf/frontend select Noninteractive' | debconf-set-selections && \
    dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --allow-remove-essential multiarch-support coreutils:i386 libc6:i386 libncurses5:i386 libstdc++6:i386 zlib1g:i386 && \
    apt-get -y autoclean && \
    apt-get -y autoremove && \
    rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/locale/* \
        /var/cache/debconf/*-old \
        /var/lib/apt/lists/* \
        /usr/share/doc/*

RUN groupadd -r quake2 && \
    useradd -r -g quake2 -s /sbin/nologin -M quake2

RUN mkdir -p /opt/quake2
COPY --chown=quake2:quake2 . /opt/quake2/

USER quake2

# EXPOSE 27910/tcp
# EXPOSE 27910/udp

WORKDIR /opt/quake2

CMD stdbuf -oL /opt/quake2/$Q2_EXECUTEABLE \
+set dedicated 1 \
+set game "$Q2_GAMEDIR" \
+set ip "$Q2_IP" \
+set port "$Q2_PORT" \
+exec server1.cfg


