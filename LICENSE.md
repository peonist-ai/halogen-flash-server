# halogen — End User License Agreement

**Version 0.1 · Effective 25 August 2026**

This Agreement is between you ("**You**") and **Peonist** ("we", "us"), and
governs your use of **halogen** (the "**Software**") — the container image
published by us containing the halogen inference engine binary, its serving
front-end, and supporting scripts.

By downloading, running, or otherwise using the Software, you agree to this
Agreement. If you do not agree, do not use the Software.

---

## 1. What this covers, and what it does not

This Agreement covers **only** the parts of the Software that we wrote: the
halogen engine binary, the serving front-end, the benchmark tooling, and the
container packaging.

It does **not** cover:

- **Model weights.** The Software contains no model weights. Weights are
  obtained separately and are licensed separately, including by their original
  authors. Nothing here grants you any right to any model weights. It is your
  responsibility to comply with the terms attached to whatever weights you
  load.
- **Third-party components** redistributed inside the image — the AMD ROCm
  runtime and libraries, the Python interpreter, and Python packages. Each is
  governed by its own license, reproduced in `THIRD-PARTY-NOTICES.md` in this
  directory and inside the image. Where a third-party license conflicts with
  this Agreement, **the third-party license governs that component.**

## 2. License grant

Subject to this Agreement, we grant you a worldwide, royalty-free,
non-exclusive, perpetual license to:

1. **Use and run** the Software for any purpose, **including commercial and
   production use**, on any number of machines, with no seat, core, request,
   or revenue limit, and no license key.
2. **Redistribute the Software unmodified**, including by mirroring it into
   your own container registry, provided that this Agreement and
   `THIRD-PARTY-NOTICES.md` travel with it intact and that you do not
   represent the redistributed copy as being something other than ours.

No fee is payable and no registration is required.

## 3. Restrictions

You may not:

1. **Redistribute a modified Software image to third parties**, or distribute
   a derivative and present it as halogen. Modifying your own copy for your
   own use is permitted; passing the result to others as halogen is not.
2. **Remove, obscure, or alter** the copyright notices, this Agreement, or
   `THIRD-PARTY-NOTICES.md`.
3. **Use our names or marks** — "Peonist", "halogen" — to endorse or promote
   your products without our written permission. Factually stating that your
   product runs on halogen is fine and needs no permission.

**On reverse engineering.** We do not prohibit it, and we would rather say so
plainly than pretend otherwise: the engine ships as a compiled binary
containing gfx1151 device code, and anyone with a disassembler can read those
kernels. We ask that you not redistribute derived source or kernels as your
own work. Interoperability and security research are welcome.

## 4. Benchmarking and publication — expressly permitted

**You may run benchmarks on the Software and publish the results.** No
approval, notice, or prior review by us is required. We ship `bench` and
`sweep` modes in the image specifically so that you can.

We ask only that published figures state:

1. the Software version they were produced with, and
2. **which prompt set produced them.**

The second is a technical necessity, not a legal formality. halogen's decode
throughput depends on speculative-decoding acceptance, which depends on how
predictable the generated text is — the same build measured on our own prompt
set spans roughly 2x, from about 20 tokens/s on prose to about 42 on code.
A single number without a named prompt set is not reproducible and is not
meaningful, in either direction. This is a request, and not a condition of
your license: publishing a figure without naming the prompt set does not
breach this Agreement.

## 5. No telemetry

The Software performs no telemetry, no license checks, and no usage
reporting, and it makes no callback to us of any kind. **We receive no
information whatsoever about your use of it**, and there is no configuration
that changes that.

By default it opens **no outbound network connections at all** — it listens
for the requests you send it and talks to nothing else. There is exactly one
exception, and it is off unless you switch it on: if you set
`HALOGEN_DOWNLOAD`, the Software fetches model weights at startup from the
repository you name. That is a connection to a third-party host of your
choosing, not to us, and it happens only when the weights are absent.

## 6. No warranty

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, AND NONINFRINGEMENT.

Stated concretely, because it matters for this kind of software: we do not
warrant that the Software will produce correct, accurate, or fit-for-purpose
output; that it will achieve any particular throughput on your hardware; that
it will run on any configuration other than AMD Strix Halo (gfx1151), for
which it is built exclusively; or that it will operate uninterrupted or
error-free. **Model output is generated text and may be wrong.** Do not rely
on it for safety-critical, medical, legal, or financial decisions without
independent verification.

## 7. Limitation of liability

TO THE MAXIMUM EXTENT PERMITTED BY LAW, IN NO EVENT WILL WE BE LIABLE FOR ANY
INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE DAMAGES, OR ANY LOSS
OF PROFITS, REVENUE, DATA, OR BUSINESS INTERRUPTION, ARISING OUT OF OR RELATED
TO THIS AGREEMENT OR THE SOFTWARE, WHETHER IN CONTRACT, TORT, OR OTHERWISE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGES.

OUR TOTAL AGGREGATE LIABILITY UNDER THIS AGREEMENT WILL NOT EXCEED THE GREATER
OF (A) THE AMOUNT YOU PAID US FOR THE SOFTWARE, WHICH FOR THIS VERSION IS
ZERO, OR (B) FIFTY UNITS OF THE APPLICABLE CURRENCY.

Some jurisdictions do not allow the exclusion of certain warranties or
liabilities; in those places, the exclusions above apply only to the extent
permitted, and nothing here limits liability for fraud, or for death or
personal injury caused by negligence.

## 8. Term and termination

This Agreement applies for as long as you use the Software. It terminates
automatically if you breach Section 3, and you must then stop using and
distributing the Software. Sections 1, 6, 7, and 9 survive termination.

Your rights under Section 2 for a copy you already hold are not withdrawn by
us ceasing to publish the Software.

## 9. General

This Agreement is the entire agreement between us regarding the Software and
supersedes prior discussions. If any provision is held unenforceable, the rest
remains in effect. Our failure to enforce a provision is not a waiver of it.

This Agreement is governed by the laws of the **State of Florida, United
States**, without regard to its conflict-of-law rules.

We may publish future versions of the Software under different terms; those
terms will apply to those versions, not retroactively to this one.

---

**Contact:** open an issue at https://github.com/peonist-ai/halogen-flash-server
**Copyright © 2026 Peonist. All rights reserved.**
