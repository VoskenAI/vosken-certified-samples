# SPDX-FileCopyrightText: 2026 VoskenAI Ltd <info@vosken.ai>
# SPDX-License-Identifier: Apache-2.0

CELL := wrr_arbiter
SBY  := fv_$(CELL).sby

.PHONY: all prove cover clean verdict

all: prove cover verdict

prove:
	@echo "=== [$(CELL)] prove ==="
	sby -f $(SBY) prove

cover:
	@echo "=== [$(CELL)] cover ==="
	sby -f $(SBY) cover

clean:
	rm -rf fv_$(CELL)_prove fv_$(CELL)_cover

verdict:
	@echo ""
	@if [ -f VERDICT.txt ]; then echo "VERDICT:"; cat VERDICT.txt; else echo "No VERDICT.txt yet."; fi
