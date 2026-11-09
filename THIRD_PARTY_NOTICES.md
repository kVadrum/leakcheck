# Third-party notices

leakcheck is MIT-licensed ([`LICENSE`](./LICENSE)).
It includes work derived from the project below, used under that project's license, whose notice follows.

## gitleaks

Most of leakcheck's built-in credential rules are derived from the rules in gitleaks' default configuration (`config/gitleaks.toml`, v8.30.1): the token prefixes and shapes, re-spelled as POSIX extended regexes and in places widened or narrowed.
`bin/leakcheck` marks the derived block with SPDX snippet tags and names, beside each derived rule, the gitleaks rule it follows; rules with no such note have no gitleaks counterpart.
gitleaks: <https://github.com/gitleaks/gitleaks>

```text
MIT License

Copyright (c) 2019 Zachary Rice

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
