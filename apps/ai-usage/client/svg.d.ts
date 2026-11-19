/** A picture of the app's, built into its page as a `data:` address (Vite's `?inline`). */
declare module "*.svg?inline" {
  const src: string
  export default src
}
