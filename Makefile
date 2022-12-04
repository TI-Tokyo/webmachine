REBAR3 ?= ./rebar3


all:
	@$(REBAR3) compile

distclean:
	@rm -rf ./_build

edoc:
	@$(REBAR3) edoc
