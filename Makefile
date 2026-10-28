PYTHON ?= python3
.PHONY: validate test build
validate:
	$(PYTHON) NativeDownloads/tools/validate_vitrine_9190.py

test:
	$(PYTHON) NativeDownloads/tools/test.py

build:
	$(PYTHON) NativeDownloads/tools/build.py "$(IPA)" $(BUILD_ARGS)
