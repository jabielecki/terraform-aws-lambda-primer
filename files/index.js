exports.handler = function (event, context) {
    context.succeed('hello world');
};

index.handle = function (event, context) {
    context.succeed('hello from index');
};
