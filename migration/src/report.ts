import { randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

export async function writeJson(outDir: string, fileName: string, value: unknown): Promise<string> {
  await fs.mkdir(outDir, { recursive: true });
  const filePath = path.join(outDir, fileName);
  const tmpPath = path.join(outDir, `.${fileName}.${process.pid}.${randomUUID()}.tmp`);
  const body = `${JSON.stringify(redactSecrets(value), null, 2)}\n`;

  try {
    await fs.writeFile(tmpPath, body, { encoding: "utf8", flag: "wx" });
    await fs.rename(tmpPath, filePath);
  } catch (error) {
    await fs.unlink(tmpPath).catch(() => undefined);
    throw error;
  }

  return filePath;
}

function redactSecrets(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redactSecrets);
  if (!value || typeof value !== "object") return value;
  const result: Record<string, unknown> = {};
  for (const [key, child] of Object.entries(value)) {
    const lower = key.toLowerCase();
    if (lower.includes("service_role") || lower.includes("apikey") || lower.includes("secret") || lower.includes("token") || lower.includes("password")) {
      result[key] = "[redacted]";
    } else {
      result[key] = redactSecrets(child);
    }
  }
  return result;
}
