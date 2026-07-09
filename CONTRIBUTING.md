# Contributing to Wasabi

Thanks for your interest in improving Wasabi.

## License of the project

Wasabi is **source-available** under the [PolyForm Noncommercial License 1.0.0](LICENSE).
You may read, build, modify, and use it for any noncommercial purpose. Commercial
use requires a separate license from the author.

## Contributor terms (please read before opening a pull request)

Wasabi is a dual-licensed project: the source is public under PolyForm
Noncommercial, and the author separately distributes a paid commercial build and
paid "Pro" features. For that to remain possible, the author must hold commercial
rights in the *entire* codebase — including your contributions.

**By submitting a contribution (a pull request, patch, or any code, docs, or other
material) to this project, you agree that:**

1. **You are legally entitled to submit it** — it is your own original work, or you
   have the right to submit it under these terms, and submitting it does not
   violate anyone else's rights (this is the [Developer Certificate of Origin
   1.1](https://developercertificate.org/), which your agreement here incorporates).

2. **You grant the author (Alessandro Smedile) a perpetual, worldwide,
   non-exclusive, royalty-free, irrevocable license — with the right to
   sublicense — to use, reproduce, modify, distribute, and *commercially* license
   your contribution**, including as part of a proprietary or paid version of
   Wasabi, under any license terms the author chooses.

3. **You retain copyright** in your contribution. This is a license grant, not a
   copyright assignment — you keep ownership; you are simply giving the author the
   commercial rights needed to keep the dual-license model viable.

If you cannot agree to these terms, please do not submit a contribution. If you
have questions, open an issue first.

## Practical guidelines

See [`AGENTS.md`](AGENTS.md) for build steps, code structure, Swift style, and
commit/PR conventions. There is no test target — verify changes by building
(`scripts/build-app.sh`) and exercising the affected behavior by hand, and note
your manual verification in the PR.
