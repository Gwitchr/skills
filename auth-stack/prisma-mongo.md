# Prisma + MongoDB

Schema shapes for the auth-relevant models, the Mongo `ObjectId` decorator pattern, and the `db push` workflow. This file is the canonical home for the ID convention and Mongo schema rules, the rest of the skill references back here.

## Datasource

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider     = "mongodb"
  url          = env("DATABASE_URL")
  relationMode = "prisma"
}
```

`relationMode = "prisma"` is required because MongoDB has no foreign-key support. Prisma enforces relation integrity in the application layer instead of the database. **Never** remove this, it changes how `onDelete: Cascade` is implemented (Prisma issues the cascading delete in TS, not the DB).

---

## The four Better Auth models

```prisma
model User {
  id              String   @id @default(auto()) @map("_id") @db.ObjectId
  email           String   @unique
  emailVerified   Boolean  @default(false)
  name            String?
  image           String?
  // Additional fields, declared in `auth.user.additionalFields` (see auth-config.md).
  // Names are illustrative; rename to your domain.
  role            String   @default("user")
  preferredLocale String?  @default("en")
  createdAt       DateTime @default(now())
  updatedAt       DateTime @updatedAt

  sessions Session[]
  accounts Account[]
  // …app-specific relations omitted

  @@index([role])
}

model Session {
  id        String   @id @default(auto()) @map("_id") @db.ObjectId
  token     String   @unique
  userId    String   @db.ObjectId
  expiresAt DateTime
  ipAddress String?
  userAgent String?
  createdAt DateTime @default(now())
  updatedAt DateTime @updatedAt

  user User @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId])
}

model Account {
  id                    String    @id @default(auto()) @map("_id") @db.ObjectId
  userId                String    @db.ObjectId
  accountId             String
  providerId            String
  accessToken           String?
  refreshToken          String?
  idToken               String?
  accessTokenExpiresAt  DateTime?
  refreshTokenExpiresAt DateTime?
  scope                 String?
  password              String?
  createdAt             DateTime  @default(now())
  updatedAt             DateTime  @updatedAt

  user User @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@unique([providerId, accountId])
  @@index([userId])
}

model Verification {
  id         String   @id @default(auto()) @map("_id") @db.ObjectId
  identifier String   @unique
  value      String
  expiresAt  DateTime
  createdAt  DateTime @default(now())
  updatedAt  DateTime @updatedAt

  @@index([expiresAt])
}
```

The four model **names** (`User`, `Session`, `Account`, `Verification`) are part of the Better Auth adapter contract, don't rename them. The shapes above are the minimum the adapter expects; you can add fields freely (see "Adding an additional `User` field" below).

---

## The `ObjectId` pattern, canonical reference

Every primary `id` follows the same shape:

```prisma
id String @id @default(auto()) @map("_id") @db.ObjectId
```

| Decorator           | Why                                                                  |
| ------------------- | -------------------------------------------------------------------- |
| `String`            | Prisma surfaces ObjectId as `string` in JS                           |
| `@id`               | Primary key                                                          |
| `@default(auto())`  | Tells Prisma to generate the value (it asks Mongo, not Better Auth)  |
| `@map("_id")`       | Mongo's primary key is literally `_id`; the field becomes `id` in JS |
| `@db.ObjectId`      | The 12-byte ObjectId, not a generic string blob                      |

Foreign-key columns get only `@db.ObjectId`:

```prisma
userId String @db.ObjectId
```

without the `@id` / `@default(auto())` / `@map` decorators because the value is supplied by the relation, not generated.

### Hard rules around IDs

- **Never** call `crypto.randomUUID()` or pass an `id` value into a `prisma.<model>.create()`. `@default(auto())` is the only legitimate ID source on Mongo.
- **Never** declare a foreign-key column without `@db.ObjectId`, Prisma will store it as a generic string and break the relation lookup.
- **Never** mix UUID strings and ObjectId in the same schema, pick one (it's ObjectId here).

---

## Why these models look the way they do

### `Session.token @unique`

Better Auth looks sessions up by token, not by `(userId, token)`. The unique-on-single-field index is required by the adapter contract.

### `Verification.identifier @unique` + `expiresAt` index

The magic-link plugin writes one row per `(email, purpose)`, indexed by `identifier`. The `expiresAt` index supports the cleanup query that prunes expired verifications.

### `Account.@@unique([providerId, accountId])`

A given external provider account (e.g. a Google ID, an Apple ID) maps to exactly one local user. The compound unique enforces that.

### `User.@@index([role])`

Admin dashboards filter by role. The index makes `WHERE role = "admin"` fast on a growing user base. **Every Mongo relation field needs an explicit `@@index([fkField])` under `relationMode = "prisma"`**, Prisma doesn't auto-create them, and without them every FK-filtered query becomes a full collection scan.

### Cascade behavior under `relationMode = "prisma"`

`onDelete: Cascade` on `Session` and `Account` is enforced by Prisma in TS, when a `User` row is deleted via the Prisma client, the related rows go too. **Direct Mongo writes** (e.g. via `mongosh` or another client) bypass this. Treat this as: **delete users only via Prisma**.

---

## Adding an additional `User` field

A four-place change, in this exact order:

1. **`prisma/schema.prisma`, `model User`**

   ```prisma
   model User {
     // …existing
     newField String? @default("foo")
   }
   ```

2. **`<server>/lib/auth.ts`, `auth.user.additionalFields`**

   ```ts
   user: {
     additionalFields: {
       // …existing
       newField: { type: "string", required: false, input: false, defaultValue: "foo" }
     }
   }
   ```

3. **(if the field has a default that must always be set)** mirror it in `databaseHooks.user.create.before`:

   ```ts
   data: {
     ...user,
     newField: typeof user.newField === "string" ? user.newField : "foo"
   }
   ```

   Better Auth's `defaultValue` does **not** reliably round-trip through the Prisma adapter, see [auth-config.md](auth-config.md) for the rationale.

4. **Migrate**:

   ```bash
   prisma db push       # push schema to MongoDB
   prisma generate      # regenerate Prisma client
   ```

   (Use the project's package-manager equivalent: `pnpm db:push`, `npm run db:push`, `bun run db:push`, etc.)

5. **Surface in `getAuthSession`** with a type predicate (see [session-and-routing.md](session-and-routing.md)). Never `as`-cast.

---

## `db push` vs migrations

This project uses `prisma db push` (not `prisma migrate dev`). MongoDB doesn't support Prisma's migration runner, `db push` syncs the schema directly. Trade-offs:

- ✅ Fast iteration; no migration files to maintain.
- ❌ No migration history; "what changed when" lives in git only.
- ❌ No safe in-place rollback, if a `db push` removes a field, the data is gone.

Treat `db push` against the production cluster as a **destructive operation**. Run it in a staging cluster first and verify the diff with `prisma db pull` against staging before promoting.

---

## Hard rules

- **Never** add a model without the `id String @id @default(auto()) @map("_id") @db.ObjectId` shape.
- **Never** add a relation without an explicit `@@index([fkField])`, under `relationMode = "prisma"`, Prisma does not auto-create FK indexes on Mongo.
- **Never** remove `relationMode = "prisma"`, it's load-bearing for cascades.
- **Never** rename one of the four auth models (`User`, `Session`, `Account`, `Verification`), Better Auth's adapter resolves them by name.
- **Never** set `@@unique` instead of `@unique` on `Session.token` or `Verification.identifier`, the adapter expects a single-field unique.
- **Never** run `prisma db push` against production without staging first, it's destructive.
