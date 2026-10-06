.PHONY: app run test install uninstall clean

app:
	scripts/build-app.sh

run:
	swift run AINotch

test:
	swift test

install: app
	rm -rf /Applications/AINotch.app
	cp -R build/AINotch.app /Applications/
	open /Applications/AINotch.app

uninstall:
	-/Applications/AINotch.app/Contents/MacOS/AINotch --uninstall-hooks
	rm -rf /Applications/AINotch.app

clean:
	rm -rf .build build
