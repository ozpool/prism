import {withSentryConfig} from "@sentry/nextjs";

/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  webpack: (config, {isServer}) => {
    // wagmi / RainbowKit transitive optional peers. Listing them as
    // externals stops webpack trying to bundle modules we do not use.
    config.externals.push("pino-pretty", "lokijs", "encoding");

    if (!isServer) {
      // Porto wallet support is opt-in inside wagmi/connectors; we do
      // not ship that connector. Aliasing the optional peer to `false`
      // teaches webpack to silently skip it instead of erroring.
      // Same trick for @metamask/sdk's optional react-native storage —
      // we never run inside React Native.
      config.resolve.alias = {
        ...config.resolve.alias,
        "porto/internal": false,
        porto: false,
        "@react-native-async-storage/async-storage": false,
      };
    }

    return config;
  },
};

// withSentryConfig is a no-op at runtime when no DSN is set — it just
// wires source-map upload + tunnel options. Source-map upload requires
// SENTRY_AUTH_TOKEN at build time; without it the wrapper degrades to
// regular Next builds.
export default withSentryConfig(nextConfig, {
  silent: true,
  org: process.env.SENTRY_ORG,
  project: process.env.SENTRY_PROJECT,
  tunnelRoute: "/monitoring",
  hideSourceMaps: true,
  disableLogger: true,
});
