import { defineVars } from "ui"

/** WhatsApp's own: how large the QR code to scan is, and the white it's on, whatever the scheme, so a phone's camera
 * reads it. */
export const own = defineVars({ qr: 240, paper: "#ffffff" })
