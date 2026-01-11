FROM node:20-alpine AS build

ARG PLEROMA_FE_REPO=https://git.pleroma.social/pleroma/pleroma-fe.git
ARG PLEROMA_FE_REF=2.10.0

RUN apk add --no-cache git

WORKDIR /src

RUN git clone --depth 1 --branch "$PLEROMA_FE_REF" "$PLEROMA_FE_REPO" .

RUN corepack enable
RUN yarn install --frozen-lockfile
RUN yarn build

# Provide an empty static config file so Pleroma-FE doesn't warn loudly.
RUN mkdir -p dist/static && echo '{}' > dist/static/config.json

FROM nginx:1.27-alpine

COPY docker/pleroma-fe/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist /usr/share/nginx/html
