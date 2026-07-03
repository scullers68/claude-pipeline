import assert from "node:assert/strict";
import Ajv, { type AnySchema } from "ajv";

const sharedAjv = new Ajv({ strict: false });

export function createAssertValid(schema: unknown) {
  const validate = sharedAjv.compile(schema as AnySchema);

  const assertValid = function (value: unknown): void {
    const ok = validate(value);
    assert.ok(ok, `expected value to satisfy schema: ${sharedAjv.errorsText(validate.errors)}`);
  };

  assertValid.validator = validate;
  return assertValid;
}
