import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import * as crypto from "node:crypto";

export async function writeJsonAtomically<T>(
  filePath: string,
  data: T,
): Promise<void> {
  const dir = path.dirname(filePath);
  const tmpPath = path.join(
    dir,
    `.${path.basename(filePath)}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`,
  );

  await fs.writeFile(tmpPath, JSON.stringify(data, null, 2) + os.EOL, "utf8");
  await fs.rename(tmpPath, filePath);
}
