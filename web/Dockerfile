# syntax=docker/dockerfile:1

FROM oven/bun:1 AS build

WORKDIR /app

COPY package.json bun.lock* bunfig.toml tsconfig.json ./
COPY packages ./packages

RUN bun install --frozen-lockfile
RUN bun run --filter '@wuhu/app' build

FROM node:22-slim AS production

WORKDIR /app

ENV NODE_ENV=production

COPY --from=build /app/package.json ./package.json
COPY --from=build /app/packages/app/package.json ./packages/app/package.json
COPY --from=build /app/packages/app/build ./packages/app/build
COPY --from=build /app/node_modules ./node_modules

EXPOSE 3000

ENV PORT=3000

CMD ["npx", "react-router-serve", "./packages/app/build/server/index.js"]
