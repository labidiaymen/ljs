// expect-error E_UNSUPPORTED_PROTOTYPE
String.prototype.slugify = function () {
  return this.toLowerCase();
};
