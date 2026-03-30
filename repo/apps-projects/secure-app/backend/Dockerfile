FROM registry.access.redhat.com/ubi8/nodejs-18-minimal:1-145

USER 0
WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev && chown -R 1001:0 /app

COPY server.js ./

EXPOSE 3000

USER 1001

CMD ["node", "server.js"]




