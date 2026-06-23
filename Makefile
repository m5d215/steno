APP       := steno.app
BIN       := .build/debug/steno
BUNDLE_ID := com.m5d215.steno
PREFIX    := $(HOME)/Applications
ICON      := icon/AppIcon.icns

# 開発用フレーバー: 常用版(~/Applications)と完全独立に並行起動するための別 bundle id・別出力先。
DEV_APP       := steno-dev.app
DEV_BUNDLE_ID := com.m5d215.steno.dev
DEV_DIR       := $(HOME)/.config/steno-dev

.PHONY: build install dev icon clean

# swift build → .app バンドル生成 → 署名。
# Apple Development 証明書があれば安定署名(TCC 許可が永続)、無ければ ad-hoc にフォールバック。
build:
	swift build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/steno
	cp Info.plist $(APP)/Contents/Info.plist
	mkdir -p $(APP)/Contents/Resources
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	SIGN=$$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | awk '{print $$2}'); \
	codesign --force --deep --sign "$${SIGN:--}" --identifier $(BUNDLE_ID) $(APP); \
	echo "signed with: $${SIGN:-ad-hoc}"
	@echo "built: $(APP)"

# ~/Applications へ配置(常に build し直してから入れる)。
# 署名済みバンドルを cp -R でそのまま移すので TCC 許可は維持される。
install: build
	mkdir -p $(PREFIX)
	rm -rf $(PREFIX)/$(APP)
	cp -R $(APP) $(PREFIX)/$(APP)
	@echo "installed: $(PREFIX)/$(APP)"

# 開発版を常用版と並行で起動する。別 bundle id・別出力先($(DEV_DIR))で完全独立。
# open は環境変数を渡せないので STENO_DIR は LSEnvironment(plist)に焼き込む。
# aggregate device UID はプロセス毎に一意(コード側)なので audio device も衝突しない。
# 初回は dev 用 bundle id に対して音声取得/マイク/音声認識の TCC ダイアログが一度出る。
dev:
	pkill -INT -f $(DEV_APP) 2>/dev/null || true
	swift build
	rm -rf $(DEV_APP)
	mkdir -p $(DEV_APP)/Contents/MacOS
	cp $(BIN) $(DEV_APP)/Contents/MacOS/steno
	cp Info.plist $(DEV_APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(DEV_BUNDLE_ID)" $(DEV_APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleName steno-dev" $(DEV_APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" $(DEV_APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :LSEnvironment:STENO_DIR string $(DEV_DIR)" $(DEV_APP)/Contents/Info.plist
ifneq ($(SPIKE),)
	/usr/libexec/PlistBuddy -c "Add :LSEnvironment:STENO_FINALIZE_SPIKE string $(SPIKE)" $(DEV_APP)/Contents/Info.plist
endif
	mkdir -p $(DEV_APP)/Contents/Resources
	cp $(ICON) $(DEV_APP)/Contents/Resources/AppIcon.icns
	SIGN=$$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | awk '{print $$2}'); \
	codesign --force --deep --sign "$${SIGN:--}" --identifier $(DEV_BUNDLE_ID) $(DEV_APP)
	open "$(DEV_APP)"
	@echo "dev running (id=$(DEV_BUNDLE_ID), dir=$(DEV_DIR)). logs: $(DEV_DIR)/{steno,stdout,stderr}.log  stop: pkill -INT -f $(DEV_APP)"

# アイコンを再生成する($(ICON) はコミット済み。デザインを変えた時だけ実行)。
# Swift で 1024px PNG を描き、sips で各サイズ、iconutil で .icns に束ねる。
icon:
	swift icon/make-icon.swift /tmp/steno-icon.png
	rm -rf /tmp/steno.iconset && mkdir -p /tmp/steno.iconset
	for s in 16 32 128 256 512; do \
	    sips -z $$s $$s /tmp/steno-icon.png --out /tmp/steno.iconset/icon_$${s}x$${s}.png >/dev/null; \
	    d=$$((s * 2)); \
	    sips -z $$d $$d /tmp/steno-icon.png --out /tmp/steno.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns /tmp/steno.iconset -o $(ICON)
	@echo "wrote $(ICON)"

clean:
	rm -rf .build $(APP) $(DEV_APP)
