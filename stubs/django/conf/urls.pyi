# pyre-unsafe

from typing import Any, Callable

from django.core.urlresolvers import RegexURLPattern, RegexURLResolver

def include(
    arg: Any, namespace: str = ..., app_name: str = ...
) -> RegexURLResolver: ...
def url(
    regex: str, view: Callable, kwargs: Any = ..., name: str = ..., prefix: str = ...
) -> RegexURLPattern: ...