exports._fixReplicator = function (r) {
  return function () {
    r._n = r.next.bind(r)
    r._e = r.error.bind(r)
  }
}
