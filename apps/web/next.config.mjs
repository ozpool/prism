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
      config.resolve.alias = {
        ...config.resolve.alias,
        "porto/internal": false,
        porto: false,
      };
    }

    return config;
  },
};

export default nextConfig;
