part of bloodless_server;

var _intType = reflectClass(int);
var _doubleType = reflectClass(double);
var _boolType = reflectClass(bool);
var _stringType = reflectClass(String);
var _dynamicType = reflectType(dynamic);
var _voidType = currentMirrorSystem().voidType;

final List<_Target> _targets = [];
final List<_Interceptor> _interceptors = [];
final Map<int, List<_ErrorHandler>> _errorHandlers = {};

class _Target {
  
  final UrlTemplate urlTemplate;
  final _RequestHandler handler;
  
  final String handlerName;
  final Route route;
  final String bodyType;
  
  UrlMatch _match;

  _Target(this.urlTemplate, this.handlerName, 
          this.handler, this.route, this.bodyType);
  
  bool match(Uri uri) {
    UrlMatch match = urlTemplate.match(uri.path);
    if (match != null) {
      if (route.matchSubPaths) {
        if (uri.path.endsWith("/") || match.tail.startsWith("/")) {
          _match = match;
          return true;
        }
      } else {
        if (match.tail.isEmpty) {
          _match = match;
          return true;
        }
      }
    }
    
    if (match != null && match.tail.isEmpty) {
      _match = match;
      return true;
    }
    return false;
  }

  Future handleRequest(Request req) {
    if (_match == null) {
      if (!match(req.httpRequest.uri)) {
        return null;
      }
    }

    return handler(_match, req);
  }
}

class _TargetParam {

  final dynamic value;
  final Symbol name;

  _TargetParam(this.value, [this.name]);

}

class _Interceptor {
  
  final RegExp urlPattern;
  final String interceptorName;
  final int chainIdx;
  final bool parseRequestBody;
  final _RunInterceptor runInterceptor;

  _Interceptor(this.urlPattern, this.interceptorName, 
               this.chainIdx, this.parseRequestBody, 
               this.runInterceptor);

}

class _ErrorHandler {
  
  final int statusCode;
  final RegExp urlPattern;
  final String handlerName;
  final _HandleError errorHandler;

  _ErrorHandler(this.statusCode, this.urlPattern, 
                this.handlerName, this.errorHandler);

}

class _ParamProcessors {
  
  final List<Function> processors;
  final String bodyType;
  
  _ParamProcessors(this.bodyType, this.processors);
  
}

void _scanHandlers([List<Symbol> libraries]) {
  
  var mirrorSystem = currentMirrorSystem();
  var libsToScan;
  if (libraries != null) {
    libsToScan = new List.from(libraries.map((l) => mirrorSystem.findLibrary(l)));
  } else {
    libsToScan = mirrorSystem.libraries.values;
  }

  libsToScan.forEach((LibraryMirror lib) {
    lib.declarations.values.forEach((DeclarationMirror declaration) {
      if (declaration is MethodMirror) {
        MethodMirror method = declaration;
        
        method.metadata.forEach((InstanceMirror metadata) {
          if (metadata.reflectee is Route) {
            _configureTarget(metadata.reflectee as Route, lib, method);
          } else if (metadata.reflectee is Interceptor) {
            _configureInterceptor(metadata.reflectee as Interceptor, lib, method);
          } else if (metadata.reflectee is ErrorHandler) {
            _configureErrorHandler(metadata.reflectee as ErrorHandler, lib, method);
          }
        });
      } else if (declaration is ClassMirror) {
        ClassMirror clazz = declaration;

        clazz.metadata.forEach((InstanceMirror metadata) {
          if (metadata.reflectee is Group) {
            _configureGroup(metadata.reflectee as Group, clazz);
          }
        });
      }
    });
  });

  _targets.sort((t1, t2) => t1.urlTemplate.compareTo(t2.urlTemplate));
  _interceptors.sort((i1, i2) => i1.chainIdx - i2.chainIdx);
  _errorHandlers.forEach((status, handlers) {
    handlers.sort((e1, e2) {
      var length1 = e1.urlPattern.pattern.split(r'/').length;
      var length2 = e2.urlPattern.pattern.split(r'/').length;
      return length2 - length1;
    });
  });
}

void _clearHandlers() {

  _targets.clear();
  _interceptors.clear();
  _errorHandlers.clear();

}

void _configureGroup(Group group, ClassMirror clazz) {

  var className = MirrorSystem.getName(clazz.qualifiedName);
  _logger.info("Found group: $className");

  InstanceMirror instance = null;
  try {
    instance = clazz.newInstance(new Symbol(""), []);
  } catch(e) {
    throw new SetupException(className, "Failed to create a instance of the group. Does $className have a default constructor with no arguments?");
  }

  String prefix = group.urlPrefix;
  if (prefix.endsWith("/")) {
    prefix = prefix.substring(0, prefix.length - 1);
  }

  clazz.instanceMembers.values.forEach((MethodMirror method) {

    method.metadata.forEach((InstanceMirror metadata) {
      if (metadata.reflectee is Route) {
        
        Route route = metadata.reflectee as Route;
        String urlTemplate = route.urlTemplate;
        if (!urlTemplate.startsWith("/")) {
          urlTemplate = "$prefix/$urlTemplate";
        } else {
          urlTemplate = "$prefix$urlTemplate";
        }
        var newRoute = new Route._fromGroup(urlTemplate, route.methods, route.responseType, 
            route.allowMultipartRequest, route.matchSubPaths);

        _configureTarget(newRoute, instance, method);
      } else if (metadata.reflectee is Interceptor) {

        Interceptor interceptor = metadata.reflectee as Interceptor;
        String urlPattern = interceptor.urlPattern;
        if (!urlPattern.startsWith("/")) {
          urlPattern = "$prefix/$urlPattern";
        } else {
          urlPattern = "$prefix$urlPattern";
        }
        var newInterceptor = new Interceptor._fromGroup(urlPattern, interceptor.chainIdx, interceptor.parseRequestBody);

        _configureInterceptor(newInterceptor, instance, method);
      } else if (metadata.reflectee is ErrorHandler) {
        
        ErrorHandler errorHandler = metadata.reflectee as ErrorHandler;
        String urlPattern = errorHandler.urlPattern;
        if (!urlPattern.startsWith("/")) {
          urlPattern = "$prefix/$urlPattern";
        } else {
          urlPattern = "$prefix$urlPattern";
        }
        var newErrorHandler = new ErrorHandler._fromGroup(errorHandler.statusCode, urlPattern);
        
        _configureErrorHandler(newErrorHandler, instance, method);
      }
    });

  });
}

void _configureInterceptor(Interceptor interceptor, ObjectMirror owner, MethodMirror handler) {

  var handlerName = MirrorSystem.getName(handler.qualifiedName);
  if (!handler.parameters.where((p) => !p.isOptional).isEmpty) {
    throw new SetupException(handlerName, "Interceptors must have no required arguments.");
  }

  var caller = () {

    _logger.finer("Invoking interceptor: $handlerName");
    owner.invoke(handler.simpleName, []);

  };

  var name = MirrorSystem.getName(handler.qualifiedName);
  _interceptors.add(new _Interceptor(new RegExp(interceptor.urlPattern), name,
                                     interceptor.chainIdx, interceptor.parseRequestBody, 
                                     caller));

  _logger.info("Configured interceptor for ${interceptor.urlPattern} : $handlerName");
}

void _configureErrorHandler(ErrorHandler errorHandler, ObjectMirror owner, MethodMirror handler) {

  var handlerName = MirrorSystem.getName(handler.qualifiedName);
  if (!handler.parameters.where((p) => !p.isOptional).isEmpty) {
    throw new SetupException(handlerName, "error handlers must have no required arguments.");
  }

  var caller = () {

    _logger.finer("Invoking error handler: $handlerName");
    owner.invoke(handler.simpleName, []);

  };

  var name = MirrorSystem.getName(handler.qualifiedName);
  List<_ErrorHandler> handlers = _errorHandlers[errorHandler.statusCode];
  if (handlers == null) {
    handlers = [];
    _errorHandlers[errorHandler.statusCode] = handlers;
  }
  handlers.add(new _ErrorHandler(errorHandler.statusCode, 
      new RegExp(errorHandler.urlPattern), name, caller));

  _logger.info("Configured error handler for status ${errorHandler.statusCode} : $handlerName");
}

void _configureTarget(Route route, ObjectMirror owner, MethodMirror handler) {

  var paramProcessors = _buildParamProcesors(handler);
  var handlerName = MirrorSystem.getName(handler.qualifiedName);

  var caller = (UrlMatch match, Request request) {
    
    _logger.finer("Preparing to execute target: $handlerName");

    return new Future(() {

      var httpResp = request.response;
      var pathParams = match.parameters;
      var queryParams = request.queryParams;
      
      var posParams = [];
      var namedParams = {};
      paramProcessors.processors.forEach((f) {
        var targetParam = f(pathParams, queryParams, request.bodyType, request.body, request.attributes);
        if (targetParam.name == null) {
          posParams.add(targetParam.value);
        } else {
          namedParams[targetParam.name] = targetParam.value;
        }
      });

      _logger.finer("Invoking target $handlerName");
      InstanceMirror resp = owner.invoke(handler.simpleName, posParams, namedParams);

      if (resp.type == _voidType) {
        return null;
      }

      var respValue = resp.reflectee;

      _logger.finer("Writing response for target $handlerName");
      return _writeResponse(respValue, httpResp, route.responseType, abortIfChainInterrupted: true);

    });    

  };

  _targets.add(new _Target(new UrlTemplate(route.urlTemplate), handlerName, caller, route, paramProcessors.bodyType));

  _logger.info("Configured target for ${route.urlTemplate} : $handlerName");
}

_ParamProcessors _buildParamProcesors(MethodMirror handler) {

  String bodyType = null;

  List processors = new List.from(handler.parameters.map((ParameterMirror param) {
    var handlerName = MirrorSystem.getName(handler.qualifiedName);
    var paramSymbol = param.simpleName;
    var name = param.isNamed ? paramSymbol : null;

    if (!param.metadata.isEmpty) {
      var metadata = param.metadata[0];

      if (metadata.reflectee is Body) {

        var body = metadata.reflectee as Body;
        if (bodyType != null) {
          throw new SetupException(handlerName, "Invalid parameters: Only one parameter can be annotated with @Body");
        }
        bodyType = body.type;

        return (urlParams, queryParams, reqBodyType, reqBody, reqAttrs) {
          return new _TargetParam(reqBody, name);
        };

      } else if (metadata.reflectee is QueryParam) {
        var paramName = MirrorSystem.getName(paramSymbol);
        var convertFunc = _buildConvertFunction(param.type);
        var defaultValue = param.hasDefaultValue ? param.defaultValue.reflectee : null;
        var queryParamName = (metadata.reflectee as QueryParam).name;
        if (queryParamName == null) {
          queryParamName = paramName;
        }

        return (urlParams, queryParams, reqBodyType, reqBody, reqAttrs) {
          var value = queryParams[queryParamName];
          try {
            value = convertFunc(value, defaultValue);
          } catch(e) {
            throw new RequestException(handlerName, "Invalid value for $paramName: $value");
          }
          return new _TargetParam(value, name);
        };
      } else if (metadata.reflectee is Attr) {
        var paramName = MirrorSystem.getName(paramSymbol);
        var defaultValue = param.hasDefaultValue ? param.defaultValue.reflectee : null;
        var attrName = (metadata.reflectee as Attr).name;
        if (attrName == null) {
          attrName = paramName;
        }
        
        return (urlParams, queryParams, reqBodyType, reqBody, reqAttrs) {
          var value = reqAttrs[name];
          if (value == null) {
            value = defaultValue;
          }
          return new _TargetParam(value, name);
        };
      }
    }

    var convertFunc = _buildConvertFunction(param.type);
    var paramName = MirrorSystem.getName(paramSymbol);
    var defaultValue = param.hasDefaultValue ? param.defaultValue.reflectee : null;

    return (urlParams, queryParams, reqBodyType, reqBody, reqAttrs) {
      var value = urlParams[paramName];
      try {
        value = convertFunc(value, defaultValue);
      } catch(e) {
        throw new RequestException(handlerName, "Invalid value for $paramName: $value");
      }
      return new _TargetParam(value, name);
    };
  }));
  
  return new _ParamProcessors(bodyType, processors);
}

_ConvertFunction _buildConvertFunction(paramType) {
  if (paramType == _stringType || paramType == _dynamicType) {
    return (String value, defaultValue) => value != null ? value : defaultValue;
  }
  if (paramType == _intType) {
    return (String value, defaultValue) => value != null ? int.parse(value) : defaultValue;
  }
  if (paramType == _doubleType) {
    return (String value, defaultValue) => value != null ? double.parse(value) : defaultValue;
  }
  if (paramType == _boolType) {
    return (String value, defaultValue) => value != null ? value.toLowerCase() == "true" : defaultValue;
  }

  return (String value, defaultValue) => null;
}