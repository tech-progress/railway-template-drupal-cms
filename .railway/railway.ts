import { defineRailway, github, group, project, service, volume } from "railway/iac";
import defaults from "../template-defaults.json" with { type: "json" };

// Drupal CMS 2.2.10 (Drupal core 11.4.13, Drush 13.8.1) built by the root
// Dockerfile of the public distribution repository from release-v1, on the
// official Drupal image (PHP 8.4, Apache); PostgreSQL 18.7. Images pinned by
// index digest; keep in sync with the Dockerfile and compose.yaml
// (scripts/verify.sh checks).
export const POSTGRES_IMAGE =
  "postgres:18.7-alpine@sha256:0115267ab5a509022df9319c77be365cef335adb71556c75f60f5360ee247e71";
// `railway templates create` rejects a repository source the Railway GitHub
// App cannot read, so the source project can be applied with
// DRUPAL_IAC_SEED=1 (the Dockerfile's base image) and
// restore-template-draft.sh puts the repository back into the draft.
export const APP_SEED_IMAGE =
  "drupal:11.4.13-php8.4-apache-trixie@sha256:60a02ee14c147aad32025da047d16c2251331788e0d912ce23029138d0ad6e85";
const APP_SOURCE = github("tech-progress/railway-template-drupal-cms", { branch: "release-v1", rootDirectory: "/" });
export const APP_BUILD = {
  builder: "DOCKERFILE",
  dockerfilePath: "Dockerfile",
  watchPatterns: ["/Dockerfile", "/site/**", "/config/**", "/scripts/drupal-*"],
} as const;

// Source-project secrets come from the applying shell (DRUPAL_IAC_<NAME>) and
// are empty without it, so the services refuse to start. Never derive them
// here: in railway@3.6.0 ctx.randomString is a SHA-256 of public inputs, and a
// { generator } value is stored by `railway config apply` as literal text.
// Marketplace deployments get ${{secret(...)}} defaults from
// template-defaults.json, restored into the draft by restore-template-draft.sh.
const hostSecret = (name: string): string => (globalThis as any).process?.env?.[`DRUPAL_IAC_${name}`] ?? "";
const seed = (globalThis as any).process?.env?.DRUPAL_IAC_SEED === "1";
const restart = { restartPolicyType: "ON_FAILURE", restartPolicyMaxRetries: 10 } as const;

export default defineRailway(() => {
  const files = volume("Drupal Files", { sizeMB: 5_000 });
  const pgData = volume("PostgreSQL Data", { sizeMB: 5_000 });

  const postgres = service("PostgreSQL", {
    source: { image: POSTGRES_IMAGE },
    volumeMounts: { "/var/lib/postgresql": pgData },
    deploy: restart,
    env: { ...defaults.PostgreSQL, POSTGRES_PASSWORD: hostSecret("POSTGRES_PASSWORD") },
  });

  const drupal = service("Drupal CMS", {
    ...(seed ? { source: { image: APP_SEED_IMAGE } } : { source: APP_SOURCE, build: APP_BUILD }),
    healthcheck: "/user/login",
    healthcheckTimeout: 600,
    volumeMounts: { "/var/lib/drupal": files },
    deploy: restart,
    env: {
      ...defaults["Drupal CMS"],
      DRUPAL_HASH_SALT: hostSecret("HASH_SALT"),
      DRUPAL_ADMIN_PASSWORD: hostSecret("ADMIN_PASSWORD"),
    },
  });

  return project("drupal-cms", {
    resources: [group("Drupal CMS", [drupal, files]), group("Data", [postgres, pgData])],
  });
});
