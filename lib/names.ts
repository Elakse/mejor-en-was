const NAMES = [
  "Waffle",
  "Nacho",
  "Churro",
  "Panda",
  "Mango",
  "Tofu",
  "Biscuit",
  "Noodle",
  "Pickle",
  "Bean",
  "Emu",
  "Yeti",
  "Gnome",
  "Otter",
  "Loom",
  "Cactus",
  "Nugget",
  "Pepper",
  "Muffin",
  "Rocket",
];

const KEY = "mejor-en-was-name";

export function randomName(): string {
  return NAMES[Math.floor(Math.random() * NAMES.length)];
}

export function storedName(): string {
  if (typeof window === "undefined") return randomName();
  const existing = window.localStorage.getItem(KEY);
  if (existing) return existing;
  const fresh = randomName();
  window.localStorage.setItem(KEY, fresh);
  return fresh;
}

export function rememberName(name: string) {
  if (typeof window === "undefined") return;
  window.localStorage.setItem(KEY, name);
}
