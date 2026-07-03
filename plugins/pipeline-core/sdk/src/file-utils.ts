import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import * as crypto from "node:crypto";

export async function writeJsonAtomically<T>(
  filePath: string,
  data: T,
): Promise<void> {
  const { dir, base } = path.parse(filePath);
  const tmpPath = path.join(
    dir,
    `.${base}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`,
  );

  const content = `${JSON.stringify(data, null, 2)}${os.EOL}`;
  await fs.writeFile(tmpPath, content, "utf8");
  await fs.rename(tmpPath, filePath);
}
