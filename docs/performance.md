# Measured

**Every number here is the published image at its defaults on an AMD Ryzen
AI Max+ 395 (128 GB) at about 85 W of sustained package power**, one
checkpoint a machine, with the conditions each table names. Decode depends
on how predictable the text is: quote the row for the kind of text you
run, never one number for all of them.

## 0.18.20 against 0.18.19

The 0.18.20 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.19 table below; 0.18.19 is the left figure of each pair, and each figure is the mean of four runs taken in alternating order. A single request decodes and reads prompts as fast as on 0.18.19. On ht43 the 8,192-token cache-off run fell into two speed bands again (one 0.18.20 run in the slower band, a state of that machine, not of the release); that figure is the mean of the faster band. Served, two requests decoding at once are about 20% faster in total than on 0.18.19 and three about 9% (greedy; sampled, two about 7% and three up to 3%), a request alone is unchanged, and every reply at temperature 0 is identical to 0.18.19's:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 66.14 / 66.12 tok/s | 67.44 / 67.44 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,874 / 1,820 vs 1,875 / 1,821 | 1,817 / 1,850 vs 1,817 / 1,849 |
| prefill cache on (cold), 8,192 / 32,768 | 1,789 / 1,849 vs 1,787 / 1,849 | 1,800 / 1,851 vs 1,800 / 1,849 |
| two requests decoding at once, served, greedy, total | 84.81 / 101.64 tok/s | 87.28 / 105.12 tok/s |
| three requests decoding at once, served, greedy, total | 98.26 / 107.23 tok/s | 101.07 / 109.92 tok/s |

## 0.18.19 against 0.18.18

The 0.18.19 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.18 table below; 0.18.18 is the left figure of each pair, and each figure is the mean of four runs taken in alternating order (six on ht43). Generation with drafting reads about 0.4 to 0.5% above 0.18.18's, and prefill is unchanged. On ht43 the 8,192-token cache-off and 32,768-token cache-on runs fell into two speed bands in both images (a state of that machine, not of the release); those two figures are the means of the faster band. Served, three requests decoding at once are 2.6% (ht43) to 3.5% (v2) faster in total than on 0.18.18, a request alone 0.4% to 0.9%, two at once unchanged, and every reply at temperature 0 is identical to 0.18.18's:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 66.09 / 66.41 tok/s | 67.15 / 67.41 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,877 / 1,822 vs 1,879 / 1,823 | 1,814 / 1,848 vs 1,817 / 1,848 |
| prefill cache on (cold), 8,192 / 32,768 | 1,790 / 1,851 vs 1,790 / 1,852 | 1,800 / 1,849 vs 1,800 / 1,848 |
| three requests decoding at once, served, greedy, total | 95.49 / 98.84 tok/s | 98.16 / 100.76 tok/s |

## 0.18.18 against 0.18.17

The 0.18.18 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.17 table below; 0.18.17 is the left figure of each pair, and each figure is the mean of four runs taken in alternating order. Generation and prefill are unchanged, every row within its run-to-run spread:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 66.56 / 66.58 tok/s | 67.78 / 67.77 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,874 / 1,820 vs 1,876 / 1,821 | 1,820 / 1,850 vs 1,821 / 1,849 |
| prefill cache on (cold), 8,192 / 32,768 | 1,785 / 1,847 vs 1,787 / 1,848 | 1,801 / 1,850 vs 1,807 / 1,851 |

## 0.18.17 against 0.18.16

The 0.18.17 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.16 table below; 0.18.16 is the left figure of each pair, and each figure is the mean of four runs taken in alternating order. Generation and prefill are unchanged, every row within its run-to-run spread:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 66.64 / 66.64 tok/s | 67.54 / 67.53 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,877 / 1,823 vs 1,877 / 1,823 | 1,821 / 1,851 vs 1,821 / 1,848 |
| prefill cache on (cold), 8,192 / 32,768 | 1,788 / 1,849 vs 1,788 / 1,851 | 1,804 / 1,850 vs 1,807 / 1,852 |

## 0.18.16 against 0.18.15

The 0.18.16 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.15 table below; 0.18.15 is the left figure of each pair. Generation with drafting reads about 1.5% above 0.18.15's figure and at or above 0.18.14's: the answer guard no longer costs any of it, and the reply-end keep is off by default. Prefill is unchanged:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 65.94 / 66.80 tok/s | 66.47 / 67.54 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,874 / 1,821 vs 1,876 / 1,822 | 1,824 / 1,851 vs 1,824 / 1,856 |
| prefill cache on (cold), 8,192 / 32,768 | 1,789 / 1,849 vs 1,786 / 1,850 | 1,807 / 1,854 vs 1,809 / 1,856 |

## 0.18.15 against 0.18.14

The 0.18.15 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.14 table below; 0.18.14 is the left figure of each pair. Generation with drafting reads about 1% lower: the answer guard and the reply-end keep, both on by default, each cost a little of it (with `HALOGEN_ANSWER_GUARD=0` and `HALOGEN_FORK=0` it reads 0.18.14's figure). Prefill is unchanged:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 66.66 / 65.88 tok/s | 67.16 / 66.11 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,876 / 1,822 vs 1,878 / 1,824 | 1,824 / 1,854 vs 1,806 / 1,849 |
| prefill cache on (cold), 8,192 / 32,768 | 1,791 / 1,848 vs 1,793 / 1,849 | 1,811 / 1,859 vs 1,805 / 1,858 |

## 0.18.14 against 0.18.13

The published 0.18.14 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.13 table below; 0.18.13 is the left figure of each pair:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 66.10 / 66.92 tok/s | 66.24 / 67.78 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,877 / 1,822 vs 1,878 / 1,824 | 1,832 / 1,865 vs 1,830 / 1,864 |
| prefill cache on (cold), 8,192 / 32,768 | 1,787 / 1,850 vs 1,792 / 1,850 | 1,815 / 1,864 vs 1,811 / 1,861 |

## 0.18.13 against 0.18.12

The published 0.18.13 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.12 table below; 0.18.12 is the left figure of each pair. Every row runs one request at a time, so this release's changes for several requests at once (see the changelog) do not enter them:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 65.98 / 66.04 tok/s | 66.22 / 66.22 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,878 / 1,821 vs 1,879 / 1,821 | 1,830 / 1,858 vs 1,837 / 1,869 |
| prefill cache on (cold), 8,192 / 32,768 | 1,789 / 1,849 vs 1,784 / 1,850 | 1,812 / 1,864 vs 1,815 / 1,864 |

## 0.18.12 against 0.18.11

The published 0.18.12 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.11 table below; 0.18.11 is the left figure of each pair:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 64.0 / 66.1 tok/s | 65.1 / 66.1 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,833 / 1,783 vs 1,877 / 1,822 | 1,762 / 1,808 vs 1,835 / 1,865 |
| prefill cache on (cold), 8,192 / 32,768 | 1,746 / 1,808 vs 1,787 / 1,849 | 1,743 / 1,809 vs 1,815 / 1,864 |

## 0.18.11 against 0.18.10

The published 0.18.11 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.10 table below; 0.18.10 is the left figure of each pair:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 64.1 / 64.2 tok/s | 65.2 / 65.0 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,835 / 1,784 vs 1,836 / 1,785 | 1,766 / 1,811 vs 1,766 / 1,814 |
| prefill cache on (cold), 8,192 / 32,768 | 1,751 / 1,811 vs 1,752 / 1,811 | 1,747 / 1,809 vs 1,747 / 1,809 |
| three requests at once, greedy code, total | 74.6 / 91.6 tok/s | 72.7 / 88.8 tok/s |
| four requests at once, greedy code, total | 85.3 / 103.0 tok/s | 83.7 / 99.4 tok/s |

The last two rows compare 0.18.11 with `HALOGEN_SPEC_GROUP=0` (0.18.10's way of decoding three or four requests; the device code is the same) against its default, on two further machines of the same kind for each checkpoint: each request its own short prompt, 384 tokens, the prompt cache off, the mean of two server starts on each machine. Sampled prose (temperature 0.7) gains 13 to 14% at three requests and 9 to 10% at four; one, two, six and eight requests decode as before.

## 0.18.10 against 0.18.9

The published 0.18.10 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.9 table below; 0.18.9 is the left figure of each pair:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 64.6 / 64.7 tok/s | 64.7 / 64.7 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,799 / 1,746 vs 1,838 / 1,787 | 1,720 / 1,763 vs 1,757 / 1,803 |
| prefill cache on (cold), 8,192 / 32,768 | 1,706 / 1,765 vs 1,753 / 1,813 | 1,686 / 1,751 vs 1,740 / 1,802 |

From this table on, the cache-on rows use the image's corrected `sweep`, whose timed requests share nothing with its own calibration request, for both images in the pair. The earlier tables' cache-on rows were measured with the previous `sweep`, which the prompt cache served in part (about 3% at 8,192 and 1 to 2% at 32,768 on one machine), so compare cache-on rows within one table, not across this one. The cache-off rows are unaffected.

## 0.18.9 against 0.18.8

The published 0.18.9 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.8 table below; 0.18.8 is the left figure of each pair:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 64.0 / 64.0 tok/s | 64.8 / 64.8 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,798 / 1,741 vs 1,801 / 1,744 | 1,719 / 1,757 vs 1,723 / 1,762 |
| prefill cache on (cold), 8,192 / 32,768 | 1,758 / 1,782 vs 1,758 / 1,784 | 1,748 / 1,774 vs 1,750 / 1,774 |

The 8-bit KV cache (`HALOGEN_KV8=1`, opt-in), v2 on each of the two machines, an A/B against the default on one image in one session (a development build of the same cache): the `bench` mean 64.24 / 63.87 tok/s (-0.6%) on one machine and 64.91 / 64.79 tok/s (-0.2%) on the other; serial greedy decode of 256 tokens after a 32,000-token prompt 38.19 / 37.45 tok/s (-1.9%) and 38.59 / 37.94 tok/s (-1.7%); prefill at 8,192 and 32,768, cache on and off, within 0.1% on both. The KV pool at the default 524,288 positions takes 8.2 GiB instead of 14.4 (the 0.18.9 image's startup line, both machines).

## 0.18.8 against 0.18.7

The published 0.18.8 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.7 table below; 0.18.7 is the left figure of each pair:

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean | 64.2 / 64.2 tok/s | 64.5 / 64.6 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,804 / 1,745 vs 1,801 / 1,745 | 1,725 / 1,761 vs 1,725 / 1,761 |
| prefill cache on (cold), 8,192 / 32,768 | 1,762 / 1,785 vs 1,760 / 1,786 | 1,756 / 1,780 vs 1,757 / 1,781 |

The ht43 cache-on row is the median of four runs an image; a single run of either image read up to 3% lower at 32k.

A long conversation after many short ones, v2 on both machines, 0.18.8's server with `HALOGEN_CACHE_EVICT=1` (0.18.7's rule) against its default: a 174,000-token conversation's next turn, after 24 and after 40 other short conversations (each about 1,700 tokens with its own system prompt), started in 104.7 / 105.6 s under 0.18.7's rule and 1.17 / 1.11 s under the default on the first machine, 97.1 / 97.6 s and 1.13 / 1.07 s on the second.

## 0.18.7 against 0.18.6

The published 0.18.7 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.6 table below: v2 and the GGUF on one Ryzen AI Max+ 395 (128 GB) at about 85 W of sustained package power, ht43 on another at its stock settings, about 120 W. 0.18.6 is the left figure of each pair.

| | v2 | ht43 |
|---|---|---|
| one-word answers, greedy (six prompts, five times each): 0.18.6 / 0.18.7 | 41.4 / 72.3 tok/s | 41.7 / 71.7 tok/s |
| long replies, greedy, 512 tokens (four prompts, twice each) | 69.6 / 69.6 tok/s | 69.7 / 69.9 tok/s |
| sampled, temperature 0.7, top_k 20, top_p 0.95, 512 tokens (two prompts, four seeds) | 69.5 / 69.8 tok/s | 66.8 / 67.1 tok/s |
| `bench` with drafting over ten prompt shapes, greedy, mean | 64.4 / 64.4 tok/s | 64.7 / 64.7 tok/s |
| prefill cache off, 8,192 / 32,768 | 1,804 / 1,745 vs 1,805 / 1,745 | 1,724 / 1,764 vs 1,722 / 1,759 |
| prefill cache on (cold), 8,192 / 32,768 | 1,762 / 1,786 vs 1,763 / 1,787 | 1,752 / 1,772 vs 1,753 / 1,777 |

UD-IQ4_XS (unsloth's GGUF with the draft head file beside it), on the v2 machine: one-word answers 30.7 / 54.0 tok/s, long replies greedy 53.1 / 57.8 tok/s, sampled 49.1 / 49.5 tok/s.

The one-word, long and sampled rows count decode time after the first token, two runs an image; the sampled rows read as a range, since sampled text differs from run to run.

## 0.18.6 against 0.18.5

The published 0.18.6 image at its defaults (prompt cache on unless a row says otherwise, thinking off), each row an A/B pair on one machine in one session, the same machines as the 0.18.5 table below: v2 on one Ryzen AI Max+ 395 (128 GB) at about 85 W of sustained package power, ht43 on another at its stock settings, about 120 W. 0.18.5 is the left figure of each pair.

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, greedy, mean: 0.18.5 / 0.18.6 | 64.2 / 64.2 tok/s | 64.6 / 64.6 tok/s |
| prefill cache off, 8,192 / 32,768: 0.18.5 / 0.18.6 | 1,804 / 1,746 vs 1,806 / 1,747 | 1,728 / 1,768 vs 1,724 / 1,767 |
| prefill cache on (cold), 8,192 / 32,768: 0.18.5 / 0.18.6 | 1,763 / 1,787 vs 1,763 / 1,788 | 1,755 / 1,777 vs 1,757 / 1,782 |
| sampled, temperature 0.7, top_p 0.8, the two code prompts: 0.18.5 / 0.18.6 | 69.1 / 75.5 tok/s | 68.7 / 77.2 tok/s |
| sampled, temperature 0.7, top_p 0.8, all ten prompts | 61.1 / 63.8 tok/s | 61.3 / 64.5 tok/s |
| sampled, temperature 1.0, top_p 0.95, the two code prompts | 67.9 / 72.6 tok/s | 67.1 / 73.3 tok/s |
| sampled, temperature 1.0, top_p 0.95, all ten prompts | 58.9 / 61.2 tok/s | 59.2 / 61.4 tok/s |

The sampled rows are means over four seeds a prompt and two runs an image, one request at a time; sampled text differs from run to run, so read them as a range.

## 0.18.5 against 0.18.4

The published 0.18.5 image at its defaults (prompt cache on unless a row says otherwise, greedy, thinking off), each row an A/B pair on one machine in one session, the same machine class as the 0.18.0 tables below: v2 on one Ryzen AI Max+ 395 (128 GB) at about 85 W of sustained package power, ht43 on another at its stock settings, about 120 W. 0.18.4 is the left figure of each pair.

| | v2 | ht43 |
|---|---|---|
| `bench` with drafting over ten prompt shapes, mean: 0.18.4 / 0.18.5 | 60.2 / 64.2 tok/s | 61.5 / 64.7 tok/s |
| `sweep` decode (tg128): 0.18.4 / 0.18.5 | 60.5 / 64.9 tok/s | 60.4 / 63.0 tok/s |
| prefill cache off, 8,192 / 32,768: 0.18.4 / 0.18.5 | 1,805 / 1,745 vs 1,808 / 1,748 | 1,720 / 1,759 vs 1,725 / 1,762 |
| prefill cache on (cold), 8,192 / 32,768: 0.18.4 / 0.18.5 | 1,762 / 1,786 vs 1,765 / 1,787 | 1,745 / 1,771 vs 1,751 / 1,774 |
| an agent's strict tool call, decode speed, the tool-call drafter on vs off (off = 0.18.4's path): greedy / sampled T 1.0 / sampled T 0.7 | +17 to +20% / +24% / -1% | +15 to +16% / +16% / +5% |

The sampled tool-call row is the client's clock over a ten-turn agent session with strict tools; sampled sessions differ from run to run, so it is a range.

## 0.18.0, both checkpoints

The published 0.18.0 image at its defaults (the prompt cache on unless a row
says otherwise, greedy, thinking off), one checkpoint a machine: AMD Ryzen AI
Max+ 395, 128 GB, Ubuntu 24.04 with kernel 6.17 and no kernel boot options,
about 85 W of sustained package power, the GPU clock at a median 2,358 MHz
during prefill and 2,500 to 2,750 MHz during decode. On the reference machine
described below, the same image reads within about 1% of the v2 prefill
rows.

| | v2 (the default) | ht43 |
|---|---|---|
| agent turn, 30,000 to 96,000 tokens of context: median turn | **4.2 s** | **5.3 s** |
| agent turn: median first token (90th percentile) | **1.6 s** (2.3 s) | **1.6 s** (2.4 s) |
| agent turn: median answer, and its decode | 196 tokens at 83 tok/s | 263 tokens at 77 tok/s |
| first turn of a 34,174-token agent prompt, cold | 21.2 s | 22.1 s |
| decode, writing code | 72.9 tok/s | 69.0 tok/s |
| decode, editing ~8,000 tokens of code | 81.0 tok/s | 78.6 tok/s |
| decode, an agent's tool call after reading a ~3,000-token file | 70.6 tok/s | 72.9 tok/s |
| decode, English prose | 54.3 tok/s | 52.3 tok/s |
| decode, six other languages | 52.2 tok/s | 49.7 tok/s |
| decode, explaining an ~8,000-token document | 54.8 tok/s | 54.2 tok/s |
| decode, repetitive output, five prompts | 83 to 94 tok/s; 61 on one word 300 times | 80 to 91 tok/s; 63 on one word 300 times |
| prefill, `sweep`, cache off: 8,192 / 32,768 / 131,072 | 1,821 / 1,740 / 1,675 tok/s | 1,630 / 1,604 / 1,551 tok/s |
| prefill, `sweep`, cache on (a cold request): 8,192 / 32,768 | 1,646 / 1,806 tok/s | 1,502 / 1,647 tok/s |
| `sweep` decode over ten prompt shapes (tg128) | 58.5 tok/s | 55.7 tok/s |
| `bench` with drafting over ten prompt shapes, mean | 59.7 tok/s | 59.6 tok/s |

**The agent turns** are three sessions a checkpoint. Each opens with a
system prompt, four tools (read, edit and write a file, run the tests), a
task, and file reads already answered, 27,000 to 34,000 tokens in all, so
its first turn is a cold prompt; each later turn sends the conversation back with
the model's own tool call and a tool result of 800 to 3,000 tokens appended,
until the prompt passes 96,000 tokens, answers capped at 512 tokens. The prompt cache serves everything but
the new tokens, which is why the first token arrives in about 1.6 s at any
depth. The two checkpoints write different answers to the same turn, so their
turn times differ by the answers' length as much as by speed: compare the
first-token and decode rows. Times are the client's, over HTTP, from the
request to the last byte.

**Decode by kind** is one request at a time with the prompt cache off: eight
short coding prompts, four edits over ~8,000 tokens of standard-library
source, four tool-calling turns, eight English essays, six essays in Chinese,
Spanish, German, Russian, Japanese and French, two explanations of a license
text. Speed depends on how predictable the text is, so quote the row for the
kind of text you run, never one number for all of them. **The repetitive
prompts** ("print the word red ten times", count to 300, the alphabet on 25
lines, a sentence 40 times, one word 300 times) are the best case, here so it
can be compared like for like.

**Prefill on real text is slower than the `sweep` rows.** The sweep repeats
a synthetic prompt; the agent sessions' cold first turns, real source code
through the chat template with tools, ran 8 to 12% below the sweep's cold
rate.

## Earlier releases, on the reference machine

> [!NOTE]
> **Conditions, because they change the numbers:** AMD Ryzen AI Max+ 395
> (Radeon 8060S, gfx1151), 128 GB unified memory, ROCm 7.14.0, and **about
> 85 W of sustained package power**, sampled from sysfs during a
> 32,768-token prefill alongside a 2,229 MHz median clock against the part's
> 2,900 MHz top state. **Match the power envelope before comparing decode
> numbers**; it is the condition most easily left out: an independent
> tester running a 70 W-limited handheld measured 11 to 12 percent under
> both the serial and the drafted figure below, consistently on both, which
> is the signature of a lower envelope rather than a disagreement about the
> engine. Prefill reproduced on that same machine.

**The IOMMU is off on the reference machine, and it is worth 13 to 16 percent
of prefill.** Prefill is compute-bound, and on this hardware an enabled IOMMU
is a power-budget tax rather than a memory-path one: with `iommu=pt` we
measured the SoC drawing more power (122 to 127 W against 108 to 118) for lower
shader clocks (2,357 to 2,409 MHz against 2,549 to 2,713) at the same
temperature, and prefill fell from 460 to 385 tok/s at 2,048 tokens while every
bandwidth-bound number held exactly. Bisected on one kernel, so it is the IOMMU
and not the kernel version. We have not measured the IOMMU in translated mode, only off against
passthrough, and this is one machine.

The full kernel command line this was measured on is published under
[The host settings these numbers were measured
on](troubleshooting.md#the-host-settings-these-numbers-were-measured-on), because numbers you
cannot reproduce are not much use.

**These rows are w4b's**, 0.14's checkpoint with its quality sidecar (the
default until 0.15.0), in the image's default configuration of their
release; they were not re-measured on the default checkpoint since 0.15.0,
which served at the same speed or faster in a same-session comparison: full 262,144 context, prompt cache on, tuned GEMM plan loaded.
Prefill is a cold single-call prefill of real text; decode is greedy at
temperature 0. Prefill is measured by the engine's own
prefill bench; a served request with the default speculative drafter pays about
2-3% more time-to-first-token, because the draft head prefills too. The prefill
rows are 0.14.1's measurements, two runs each. The control was this same
binary with 0.14.0's prefill kernels selected, so the two arms differ in
those kernels and nothing else; it ran in the same session, on the plan this
image bakes, at a median 2,220 MHz and 85 W, and it read 1.3 to 2.4 percent
above the 0.5.3 rows it replaces. The serial decode rows are 0.2.0's and have not moved since:
the releases between them changed the scheduler, the memory layout and one
host-side sort, not the decode kernels. 0.6.0 moves the speculative rows
twice, and both moves are draft-side: the sidecar now carries the draft
head's own projections at 8 bits (its proposals are accepted more often), and
the request's own text is a second draft source (the rows below the served
one). **The four 0.12.0 rows are served, through this image, at the 1M
configuration** (`HALOGEN_ROPE_YARN=4 HALOGEN_CTX=1048576`, which caps the
prefill arena at 16,384 and turns the prompt cache off): one cold request
each, synthetic non-compressible text, thinking off, 64 tokens generated,
the rates the response's `timings` report, and the previous release beside
each from the same session with the same prompt. Decode there is 64 tokens
straight after a cold prefill, with the draft head, so it is a served rate
in that shape (and its first steps read the lookup table from disk, since
a 1M pool leaves the table little page cache), not the ten-prompt mean the
32k row is. What moved between the releases is the model's sparse-attention
indexer: its block select ran serial in the context length on one compute
unit at decode and was a fifth of a 1M prefill pass, and its scoring kernel
re-read the block keys once per 16 query rows; both are rewritten in 0.12.0
with byte-identical results.

| | halogen-flash |
|---|---|
| prefill @ 8,192 (0.14.1) | **1,584 tok/s** (TTFT 5.2 s; 1,268 on 0.14.0) |
| prefill @ 32,768 (0.14.1) | **1,567 tok/s** (TTFT 20.9 s; 1,442 on 0.14.0) |
| prefill @ 131,072 (0.14.1) | **1,517 tok/s** (86.4 s; 1,390 and 94.3 s on 0.14.0) |
| follow-up turn at 100,000 tokens of context | **~2 s** (prompt cache on, the default) |
| decode, serial greedy @ ctx 1,500 | **37.6 tok/s** |
| decode, serial greedy @ ctx 8,000 | **36.1 tok/s** |
| decode, serial greedy @ ctx 32,768 | **34.1 tok/s** |
| decode, MTP speculation @ ctx 1,500 | **44.8 tok/s** prose, **49.9 tok/s** code (0.6.0 sidecar; 42.4 / 48.3 with the 0.5.x sidecar) |
| decode, MTP speculation @ ctx 32,768, served (0.14.0) | **46.0 tok/s** mean over ten prompts (39.9 on 0.13.8 in the same session) |
| prefill @ 258,794, served, 1M configuration (0.12.0) | **1,114 tok/s** (232 s; 1,086 on 0.11.10) |
| prefill @ 1,004,581, served, 1M configuration (0.12.0) | **937 tok/s** (17.9 min; 790 and 21.2 min on 0.11.10) |
| decode, MTP speculation @ ctx 258,794, served, cold (0.12.0) | **45.0 tok/s** (42.9 on 0.11.10) |
| decode, MTP speculation @ ctx 1,004,581, served, cold (0.12.0) | **38.3 tok/s** (27.3 on 0.11.10) |
| decode, coding-agent turn, MTP alone (0.6.0 control) | **49.1 tok/s** thinking off, **49.2** thinking on |
| decode, coding-agent turn, MTP + prompt lookup (0.6.0) | **56.3 tok/s** thinking off, **55.7** thinking on |
| decode, function-calling turn, MTP + prompt lookup (0.6.0) | **53.1 tok/s** thinking off (48.8 with MTP alone) |

**The 0.6.0 rows are agent turns, not prose.** Each is the mean over six
prompts: a real coding-agent conversation (SWE-agent trajectories over real
repositories, driven by another model) or a function-calling dialogue, cut at
the start of an assistant turn, ~1,000–1,800 tokens of context, 400 tokens
generated, greedy. Prompt lookup drafts from the request's own text: when the
last three tokens of the answer already occur earlier in the conversation, the
three that followed are proposed as a chain and verified in one step, with the
draft head's own proposal opening the chain. On a coding turn about half the
generated tokens are such copies (tool-call arguments, paths, code quoting the
file being edited), thinking on or off, which is why the gain over the head
alone is 13–15% there, 6–9% on function-calling turns, and within noise on
prose and code text (the head already takes what there is). Serial on the same
prompts is 36.8 tok/s, so a coding-agent turn decodes at about 1.5x serial.
Every one of those runs produced the serial run's tokens exactly. Prompt
lookup runs while the request is the only one generating; with several
conversations generating at once the scheduler batches them instead (the
concurrency table below is unchanged by it).

Decode barely moves with depth. Serial gives up about 7% going from 1,500 to
32,768 tokens of context, a 22x increase. The 32,768 served figure is
measured through the full HTTP stack rather than on a raw token fixture, which
is the harder condition.

Two levers move these and both are one environment variable:

- **A tuned GEMM plan ships in the image and is on by default.** The matrix
  library exposes many kernels per shape, and the image carries choices
  measured on this hardware rather than picking at runtime
  (`HALOGEN_MATMUL_TUNING_FILE`). It costs nothing in quality: paired
  perplexity over 32,767 positions differs by 0.0006 nats, a confidence
  interval spanning zero. It is also *deterministic*, since every process
  reads the same decisions, so the same prompt keeps giving the same answer.
- **The prompt cache is ON by default**, which is what makes the native context
  usable in practice. A session whose prompt grows, whether an agent, a chat, or a
  document you keep asking about, does not re-read its shared prefix. Only the
  tokens you actually added get processed:

  | | first turn | every turn after |
  |---|---|---|
  | 100,000-token conversation | ~88 s | **~2 s** |
  | 10,000-token conversation | ~9 s | **~1.4 s** |

  The follow-up cost is **flat**. It does not grow as the conversation does,
  because it depends on how much you added, not on how much is already there.
  Measured over a 20-turn session growing to 108,000 tokens, every turn after
  the first landed between 2.0 and 2.3 s. See
  [Choosing a cache mode](configuration.md#choosing-a-cache-mode) for when to change it.

## Served throughput, end to end over HTTP

On 0.18.0 with the default checkpoint (the conditions of [0.18.0, both
checkpoints](#0180-both-checkpoints)), the image's own `sweep` mode measures
**1,821 tok/s at pp8192, 1,740 at pp32768 and 1,675 at pp131072** through the
full stack of chat template, tokenizer, HTTP and SSE, with the prompt cache
off. With the cache on, the default, a cold request reads 1,646 and 1,806 at
8,192 and 32,768; it also stores that request's state for the next turn.
`bench` over ten prompt shapes measures **59.7 tok/s mean with speculation**
(about 50 on prose at the low end, about 70 on code at the high end; 2.59
tokens committed per round; ht43 reads 59.6). On 0.14.1 the same two
instruments read 1,502 / 1,499 tok/s and 52.5 tok/s. Acceptance depends on
how predictable the text is, so quote the mean with the prompt set named,
never a single shape.

That run also re-checks the identity property on live traffic: **every drafter
produced byte-identical output on every case**, on both checkpoints.

Reproduce the numbers with the benchmarks baked into the image:

```bash
podman run ... ghcr.io/peonist-ai/halogen-flash-server:0.18.20 bench serial,mtp 256 low 3
podman run ... -e HALOGEN_PROMPT_CACHE=0 ghcr.io/peonist-ai/halogen-flash-server:0.18.20 sweep -p 8192,32768 -n 128
```

Run the sweep with the prompt cache off, as above. It repeats one prompt per
size, so with the cache on the repeats are cache hits and the printed mean
is hundreds of times the real prefill rate.

---
