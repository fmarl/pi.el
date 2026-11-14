import js from "@eslint/js";
import { defineConfig } from "eslint/config";
import tseslint from "typescript-eslint";

export default defineConfig(
  {
    linterOptions: { reportUnusedDisableDirectives: "error" },
  },
  js.configs.recommended,
  {
    files: ["emacs-bridge/**/*.ts"],
    extends: [tseslint.configs.strictTypeChecked, tseslint.configs.stylisticTypeChecked],
    languageOptions: {
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    rules: {
      "@typescript-eslint/consistent-type-definitions": ["error", "type"],
      "@typescript-eslint/no-confusing-void-expression": ["error", { ignoreArrowShorthand: true }],
      "@typescript-eslint/no-floating-promises": [
        "error",
        {
          allowForKnownSafeCalls: [
            { from: "package", package: "node:test", name: ["after", "describe", "it"] },
          ],
        },
      ],
      "@typescript-eslint/restrict-template-expressions": ["error", { allowNumber: true }],

      "@typescript-eslint/consistent-type-exports": "error",
      "@typescript-eslint/consistent-type-imports": "error",
      "@typescript-eslint/default-param-last": "error",
      "@typescript-eslint/explicit-module-boundary-types": "error",
      "@typescript-eslint/no-import-type-side-effects": "error",
      "@typescript-eslint/no-shadow": "error",
      "@typescript-eslint/no-unnecessary-qualifier": "error",
      "@typescript-eslint/prefer-readonly": "error",
      "@typescript-eslint/promise-function-async": "error",
      "@typescript-eslint/require-array-sort-compare": "error",
      "@typescript-eslint/strict-boolean-expressions": "error",
      "@typescript-eslint/switch-exhaustiveness-check": "error",
      eqeqeq: "error",
      "no-implicit-coercion": "error",
      "no-param-reassign": "error",
      "no-promise-executor-return": "error",
      "object-shorthand": "error",
      "prefer-template": "error",

      "no-console": "error",
      "no-restricted-properties": [
        "error",
        { object: "process", property: "exit", message: "An extension must not end Pi." },
        { object: "process", property: "exitCode", message: "An extension must not end Pi." },
        { object: "process", property: "stdout", message: "Pi owns the terminal; use ctx.ui." },
        { object: "process", property: "stderr", message: "Pi owns the terminal; use ctx.ui." },
      ],
      "no-restricted-imports": [
        "error",
        {
          patterns: [{ group: ["@mariozechner/*"], message: "Use the @earendil-works packages." }],
          paths: [
            {
              name: "@sinclair/typebox",
              message: "Import typebox, which Pi maps to its own copy.",
            },
            {
              name: "@earendil-works/pi-ai",
              importNames: ["Type", "Static", "TSchema"],
              message: "Import these from typebox.",
            },
            // no-restricted-properties sees only the global.
            { name: "process", message: "Use the global process." },
            { name: "node:process", message: "Use the global process." },
          ],
        },
      ],
    },
  },
);
