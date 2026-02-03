# syntax=docker/dockerfile:1

FROM oven/bun:1 AS build

WORKDIR /app

COPY package.json bun.lock* bunfig.toml tsconfig.json ./
COPY packages ./packages

RUN bun install --frozen-lockfile
RUN bun run --filter '@wuhu/app' build

FROM oven/bun:1-slim AS production

WORKDIR /app

ENV NODE_ENV=production

COPY --from=build /app/packages/app/server.ts ./packages/app/server.ts
COPY --from=build /app/packages/app/build ./packages/app/build
COPY --from=build /app/node_modules ./node_modules

EXPOSE 3000

ENV PORT=3000

WORKDIR /app/packages/app

CMD ["bun", "server.ts"]
