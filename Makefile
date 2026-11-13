EMACS ?= emacs
PREFIX ?= /usr/local
DATADIR ?= $(PREFIX)/share
LISPDIR ?= $(DATADIR)/emacs/site-lisp/pi
EXTENSIONDIR ?= $(DATADIR)/pi/extensions/emacs-bridge

LISP = pi.el pi.elc pi-autoloads.el
BRIDGE = index.ts bridge.ts

.PHONY: all install uninstall clean

all: pi.elc pi-autoloads.el

pi.elc: pi.el
	$(EMACS) -Q --batch --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile pi.el

pi-autoloads.el: pi.el
	$(EMACS) -Q --batch --eval \
	  '(progn (require (quote package)) (package-generate-autoloads "pi" default-directory))'

install: all
	install -d '$(DESTDIR)$(LISPDIR)' '$(DESTDIR)$(EXTENSIONDIR)'
	install -m 644 $(LISP) '$(DESTDIR)$(LISPDIR)'
	install -m 644 $(addprefix emacs-bridge/,$(BRIDGE)) '$(DESTDIR)$(EXTENSIONDIR)'

# Removes only our files, as LISPDIR may be shared.
uninstall:
	rm -f $(addprefix '$(DESTDIR)$(LISPDIR)'/,$(LISP)) \
	  $(addprefix '$(DESTDIR)$(EXTENSIONDIR)'/,$(BRIDGE))
	-rmdir '$(DESTDIR)$(LISPDIR)' '$(DESTDIR)$(EXTENSIONDIR)' 2>/dev/null

clean:
	rm -f pi.elc pi-autoloads.el
