FROM debian:stable-slim

ENV Q2_IP="localhost"
ENV Q2_PORT="27910"

RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y multiarch-support libc6:i386 libncurses5:i386 libstdc++6:i386 zlib1g:i386

RUN groupadd -r quake2 && \
    useradd -r -g quake2 -s /sbin/nologin -M quake2

RUN mkdir -p /opt/quake2
COPY --chown=quake2:quake2 . /opt/quake2/

USER quake2

EXPOSE 27910/tcp
EXPOSE 27910/udp

WORKDIR /opt/quake2

CMD /opt/quake2/r1q2ded-old \
+set dedicated 1 \
+set game arena \
+set ip "$Q2_IP" \
+set port "$Q2_PORT" \
+exec server1.cfg