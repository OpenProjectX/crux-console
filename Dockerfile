# Build stage: compiles the ClojureScript frontend and packs the uberjar
FROM clojure:temurin-17-lein AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends nodejs npm \
    && npm install -g yarn \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# fetch deps first so they cache independently of source changes
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
COPY project.clj shadow-cljs.edn ./
RUN lein with-profile base:crux-jars deps

COPY . .
RUN node_modules/.bin/shadow-cljs release app \
    && lein with-profile base:crux-jars uberjar

# Runtime stage
FROM eclipse-temurin:17-jre

WORKDIR /app
COPY --from=build /build/target/crux-console.jar ./crux-console.jar

# 5000 = console frontend, 8080 = embedded Crux HTTP API
# (the browser talks to 8080 directly, so publish both)
EXPOSE 5000 8080

# embedded Crux (RocksDB) persists here
VOLUME /app/data

ENTRYPOINT ["java", "-jar", "crux-console.jar"]
CMD ["--embed-crux", "true", "--crux-node-url-base", "\"localhost:8080\""]
