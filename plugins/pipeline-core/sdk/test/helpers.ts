import assert from "node:assert/strict";
import Ajv, { type AnySchema } from "ajv";

export function createAssertValid(schema: unknown) {
  const ajv = new Ajv({ strict: false });
  const validate = ajv.compile(schema as AnySchema);

  const assertValid = function (value: unknown): void {
    const ok = validate(value);
    assert.ok(ok, `expected value to satisfy schema: ${ajv.errorsText(validate.errors)}`);
  };

  assertValid.validator = validate;
  return assertValid;
}
