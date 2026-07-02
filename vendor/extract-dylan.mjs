// Extract @dicebear/dylan into animatable layers: priv/avatar-dylan/
//   base.svg      — face(skin) + fixed eyes (SKINCOLOR/HAIRCOLOR tokens)
//   mood/*.svg    — the 7 mouth expressions (emotion + talking frames)
//   hair/*.svg    — hair variants (HAIRCOLOR token)
//   facialHair/*.svg
//   palettes.txt  — seeded color choices
// Dylan! by Natalia Spivak, CC BY 4.0 (see vendor/dylan/LICENSE).
// Run: bun vendor/extract-dylan.mjs
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

// The dylan components import `escape` from a @dicebear/core version that no longer
// exports it; escape.xml is identity for our alphanumeric color tokens, so load each
// component with the import replaced by a local identity shim.
async function load(file) {
  const src = readFileSync(join(here, "dylan/lib/components", file), "utf8")
    .replace(/import\s*\{\s*escape\s*\}\s*from\s*['"]@dicebear\/core['"];?/,
             "const escape = { xml: (s) => String(s) };");
  const tmp = join(here, "dylan/lib/components", "_shim_" + file);
  writeFileSync(tmp, src);
  return import(tmp);
}

const { hair } = await load("hair.js");
const { facialHair } = await load("facialHair.js");
const { mood } = await load("mood.js");

const out = join(here, "..", "priv", "avatar-dylan");
// color tokens survive escape.xml (alphanumeric, no XML specials) → replaced later
const colors = { skin: "SKINCOLOR", hair: "HAIRCOLOR" };

function dump(group, table) {
  const dir = join(out, group);
  mkdirSync(dir, { recursive: true });
  const names = Object.keys(table);
  for (const name of names) writeFileSync(join(dir, `${name}.svg`), table[name]({}, colors));
  console.log(`${group}: ${names.length} → ${names.join(", ")}`);
  return names;
}

mkdirSync(out, { recursive: true });

// The fixed base, verbatim from index.js create() (face path + ears + the two
// eyes) with the skin color tokenized. Eyes are here → same across every avatar.
const base = `<path d="M19.07 30.47s1.57-20.23 21.59-20.23S62.3 30.55 62.3 30.55s9.43-.8 9.43 7.6c0 8.42-9.28 7.13-9.28 7.13S60.9 67.15 42.03 67.15c-21.11 0-23.4-20.8-23.4-20.8s-9 .72-9.93-6.25c-1.08-8.2 10.37-9.64 10.37-9.64" fill="SKINCOLOR"/><path d="m64.3 39.49.46-.41.1-.09c.12-.1-.13.1-.02.02l.24-.17q.5-.35 1.06-.62l.26-.12.05-.02.05-.02.58-.21q.6-.18 1.2-.28c.52-.08.85-.76.7-1.23-.18-.56-.67-.8-1.23-.7a9.3 9.3 0 0 0-4.87 2.43c-.38.36-.4 1.06 0 1.4.4.36 1 .4 1.4 0zm-51.8-1.16.14.01c-.27-.02-.11-.01-.04 0l.3.05.52.14.28.09.12.05c.02 0 .22.09.06.02-.14-.1 0-.04.03-.03l.15.06.26.13.47.3.27.22q.47.38.83.83c.33.4 1.07.37 1.41 0 .4-.43.36-.98 0-1.4a7.3 7.3 0 0 0-4.84-2.53c-.52-.06-1.02.5-1 1 .03.59.44.94 1 1" fill="black"/>`;
writeFileSync(join(out, "base.svg"), base);

// The two eyes as their own layer (extracted from the base's black path) so JS can
// blink them independently of ears.
const eyes = `<path d="M29.8 36.53v4.54c0 .52.46 1.02 1 1s1-.44 1-1V36.4c0-.52-.46-1.02-1-1s-1 .44-1 1M49.2 36l-.15 4.81a1 1 0 0 0 1 1c.56-.02.98-.44 1-1l.15-4.8a1 1 0 0 0-1-1 1 1 0 0 0-1 1" fill="black"/>`;
writeFileSync(join(out, "eyes.svg"), eyes);

dump("mood", mood);
dump("hair", hair);
dump("facialHair", facialHair);

// color palettes from the schema defaults (the colorful set)
writeFileSync(join(out, "palettes.txt"),
  "skin ffd6c0,c26450\nhair 000000,ff543d,fff500,1d5dff,ffffff\n");
console.log("done →", out);
