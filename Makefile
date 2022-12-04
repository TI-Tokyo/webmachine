.PHONY: compile eunit xref dialyzer
REBAR=./rebar3

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean

distclean:
	$(REBAR) clean -a

eunit:
	$(REBAR) eunit

dialyzer:
	$(REBAR) dialyzer

xref:
	$(REBAR) xref

check: eunit dialyzer xref
