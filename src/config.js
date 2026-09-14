// Ahnengalerie defaults. Deployers may still mount their own config.js on top
// (see AGENTS.md → Runtime configuration); these are the fork's baseline.
window.grampsjsConfig = {
  // Family instance: accounts are created by an admin, never self-registered.
  // The backend enforces this too (GRAMPSWEB_REGISTRATION_DISABLED=true).
  hideRegisterLink: true,
  // Shown in the login heading instead of "Gramps Web".
  appName: 'Ahnengalerie',
}
