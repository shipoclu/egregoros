FROM node:20-alpine AS build

ARG PL_FE_REPO=https://github.com/mkljczk/pl-fe.git
ARG PL_FE_REF=develop

# Build-time configuration (compile-time for pl-fe).
ARG PL_FE_BACKEND_URL=
ARG PL_FE_FE_SUBDIRECTORY=
ARG PL_FE_WITH_LANDING_PAGE=false

RUN apk add --no-cache git

WORKDIR /src

RUN git clone --depth 1 --branch "$PL_FE_REF" "$PL_FE_REPO" .

RUN corepack enable && corepack prepare pnpm@9 --activate
RUN pnpm install --frozen-lockfile

ENV BACKEND_URL=$PL_FE_BACKEND_URL
ENV FE_SUBDIRECTORY=$PL_FE_FE_SUBDIRECTORY
ENV WITH_LANDING_PAGE=$PL_FE_WITH_LANDING_PAGE

RUN pnpm --filter pl-api build
RUN pnpm --filter pl-hooks build
RUN pnpm --filter pl-fe build

FROM nginx:1.27-alpine

COPY docker/pl-fe/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/packages/pl-fe/dist /usr/share/nginx/html

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O - http://127.0.0.1/ >/dev/null 2>&1 || exit 1
