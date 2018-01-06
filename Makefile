clean:
	find . -name '*~' -exec 'rm' '-f' '{}' ';'
	rm -f logs/* feeds/*

stop:
	kill -9 `cat logs/otrad.pid`
