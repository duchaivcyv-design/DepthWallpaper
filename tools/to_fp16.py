import sys, numpy as np
from coremltools.proto import Model_pb2
src, dst = sys.argv[1], sys.argv[2]
spec = Model_pb2.Model(); spec.ParseFromString(open(src, 'rb').read())
n = 0
for layer in spec.neuralNetwork.layers:
    kind = layer.WhichOneof('layer')
    params = []
    if kind == 'convolution':
        params = [layer.convolution.weights, layer.convolution.bias]
    elif kind == 'scale':
        params = [layer.scale.scale, layer.scale.bias]
    for w in params:
        if len(w.floatValue) > 0:
            w.float16Value = np.array(w.floatValue, np.float16).tobytes()
            del w.floatValue[:]
            n += 1
open(dst, 'wb').write(spec.SerializeToString())
print('fp16 weights converted:', n)
