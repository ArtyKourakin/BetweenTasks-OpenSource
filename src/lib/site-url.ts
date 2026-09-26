/** Canonical public origin used for links shared outside the current browser. */
export const SITE_ORIGIN = "https://betweentasks.com";

export function publicUrl(path: string) {
  return `${SITE_ORIGIN}${path.startsWith("/") ? path : `/${path}`}`;
}