# Zod schemas

Runtime validation for the data layer: the three schemas each domain exports and the shared primitives they build on. Read it when adding a domain, a field, or an input the server must validate. The `XMinProps` types the schemas bind to come from the Prisma model, see [server-actions.md](server-actions.md).

One file per domain with three schemas: the base schema (the Prisma model minus system and relation-ID fields), the post schema (the base wrapped in a named object for creation), and the update schema (`BaseSchema.partial()` or a hand-rolled subset; in a multilingual project, the text fields flattened to strings plus a `language` selector).

Shared primitives go in `<schemas>/common.ts`; keep only the ones the project uses:

```typescript
import { z } from "zod";

// Localized text, multilingual projects only: one required default language, the rest nullable.
export const Languages = z.object({
  en: z.string(),
  es: z.string().nullable(),
  fr: z.string().nullable()
});
export const TextSchema = z.object({ text: Languages });

export const ImageSchema = z.object({
  imagesURLs: z.string().array(),
  main: z.boolean(),
  alt: z.string().nullable(),
  key: z.string()
});

export const ColorString = z.string().length(7).regex(/^#[0-9A-Fa-f]{6}$/);
```

A domain file:

```typescript
// <schemas>/article.ts
import { type Article } from "@prisma/client";
import { z } from "zod";
import { type SimplifyTextProp, type DBCommonData } from "types/common";
import { ColorString, TextSchema } from "./common";

// 1. Strip system fields and relation IDs.
export type ArticleMinProps = Omit<Article, DBCommonData | "authorId" | "tagIDs" | "categoryId">;

// 2. Base schema. `satisfies` makes the build fail when the Prisma model and the schema drift apart.
export const ArticleSchema = z.object({
  title: TextSchema,
  description: TextSchema,
  color: ColorString,
  active: z.boolean()
}) satisfies z.ZodType<ArticleMinProps>;

// 3. Post schema: the base wrapped in a named object.
export const PostArticleParamsSchema = z.object({ article: ArticleSchema });
export type PostArticleParamsSchemaType = z.infer<typeof PostArticleParamsSchema>;

// 4. Update schema, multilingual form: text fields flattened to strings plus a language selector.
//    Single-language projects use ArticleSchema.partial() instead.
type ArticleSimplifiedProps = SimplifyTextProp<ArticleMinProps> & { language: string };

export const ArticleUpdateParamsSchema = ArticleSchema.omit({ title: true, description: true }).extend({
  title: z.string(),
  description: z.string(),
  language: z.string() // Zod 4: z.enum(YourLanguageEnum); Zod 3: z.nativeEnum(YourLanguageEnum)
}) satisfies z.ZodType<ArticleSimplifiedProps>;
export type ArticleUpdateParamsSchemaType = z.infer<typeof ArticleUpdateParamsSchema>;
```

## Rules

- Every base schema carries `satisfies z.ZodType<XMinProps>`.
- Prisma enums become `z.enum(YourPrismaEnum)` in Zod 4 and `z.nativeEnum(YourPrismaEnum)` in Zod 3, never a hand-written string union.
- Convert query strings and `FormData` with `z.coerce.number()`, `z.coerce.date()`, and `z.coerce.string()`.
- `Omit<Model, DBCommonData | "...IDs">` strips system and relation-ID fields. The `*IDs` arrays are a MongoDB many-to-many idiom; on SQL, name the foreign-key columns the schema has.
- Post schemas wrap the domain schema in a named object, one schema per purpose.
- Infer types with `z.infer<typeof Schema>`; never write the shape twice.
