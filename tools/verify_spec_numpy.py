"""Chạy thực thi numpy các lớp trong spec Core ML và so với onnxruntime (cùng ảnh đầu vào)."""
import sys, numpy as np
from coremltools.proto import Model_pb2
import onnxruntime as ort

SPEC = sys.argv[1]; ONNX = sys.argv[2]
spec = Model_pb2.Model()
spec.ParseFromString(open(SPEC, 'rb').read())
nn = spec.neuralNetwork
MEAN = np.array([0.485, 0.456, 0.406], np.float32); STD = np.array([0.229, 0.224, 0.225], np.float32)

rng = np.random.default_rng(0)
yy, xx = np.mgrid[0:320, 0:320]
img = np.zeros((320, 320, 3), np.float32)
img[..., 0] = 40 + 0.1 * xx
img[..., 1] = 60
img[..., 2] = 200 * (((yy - 160) ** 2 + (xx - 160) ** 2) < 90 ** 2) + 30  # hình tròn sáng, nền tối
img[..., 0] += 150 * (((yy - 120) ** 2 + (xx - 220) ** 2) < 40 ** 2)
img = np.clip(img, 0, 255)

# Tham chiếu onnxruntime
x = ((img / 255.0 - MEAN) / STD).transpose(2, 0, 1)[None].astype(np.float32)
sess = ort.InferenceSession(ONNX, providers=['CPUExecutionProvider'])
ref = sess.run(['1959'], {'input.1': x})[0][0, 0]

# Thực thi spec
t = {}
pre = [p for p in nn.preprocessing][0]
chw = img.transpose(2, 0, 1)
bias = np.array([pre.scaler.redBias, pre.scaler.greenBias, pre.scaler.blueBias], np.float32)
t['input.1'] = chw * pre.scaler.channelScale + bias[:, None, None]  # đầu vào ảnh -> preprocessing

def conv(inp, layer):
    p = layer.convolution
    kh, kw = p.kernelSize; sh, sw = p.stride
    ba = p.valid.paddingAmounts.borderAmounts
    pt, pb, pl, pr = ba[0].startEdgeSize, ba[0].endEdgeSize, ba[1].startEdgeSize, ba[1].endEdgeSize
    dh, dw = p.dilationFactor
    oc = p.outputChannels; ic = p.kernelChannels
    raw = p.weights.float16Value
    W = (np.frombuffer(raw, np.float16).astype(np.float32) if len(raw) else np.array(p.weights.floatValue, np.float32)).reshape(oc, ic, kh, kw)
    if p.hasBias:
        rb = p.bias.float16Value
        b = np.frombuffer(rb, np.float16).astype(np.float32) if len(rb) else np.array(p.bias.floatValue, np.float32)
    else:
        b = None
    x = np.pad(inp, ((0, 0), (pt, pb), (pl, pr)))
    ekh = (kh - 1) * dh + 1; ekw = (kw - 1) * dw + 1
    H = (x.shape[1] - ekh) // sh + 1; Wd = (x.shape[2] - ekw) // sw + 1
    out = np.zeros((oc, H, Wd), np.float32)
    for i in range(kh):
        for j in range(kw):
            patch = x[:, i * dh: i * dh + H * sh: sh, j * dw: j * dw + Wd * sw: sw]
            out += np.tensordot(W[:, :, i, j], patch, axes=([1], [0]))
    if b is not None: out += b[:, None, None]
    return out

def upsample_bilinear(inp, layer):
    p = layer.upsample
    fh, fw = p.scalingFactor
    C, H, Wd = inp.shape
    OH, OW = int(H * fh), int(Wd * fw)
    ys = (np.arange(OH) + 0.5) / fh - 0.5; xs = (np.arange(OW) + 0.5) / fw - 0.5
    ys = np.clip(ys, 0, H - 1); xs = np.clip(xs, 0, Wd - 1)
    y0 = np.floor(ys).astype(int); x0 = np.floor(xs).astype(int)
    y1 = np.minimum(y0 + 1, H - 1); x1 = np.minimum(x0 + 1, Wd - 1)
    wy = (ys - y0)[None, :, None]; wx = (xs - x0)[None, None, :]
    a = inp[:, y0][:, :, x0]; b_ = inp[:, y0][:, :, x1]
    c = inp[:, y1][:, :, x0]; d = inp[:, y1][:, :, x1]
    return (a * (1 - wx) + b_ * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy

def pool_max(inp, layer):
    p = layer.pooling
    kh, kw = p.kernelSize; sh, sw = p.stride
    C, H, Wd = inp.shape
    OH = (H - kh) // sh + 1; OW = (Wd - kw) // sw + 1
    out = np.full((C, OH, OW), -np.inf, np.float32)
    for i in range(kh):
        for j in range(kw):
            out = np.maximum(out, inp[:, i: i + OH * sh: sh, j: j + OW * sw: sw])
    return out

for layer in nn.layers:
    kind = layer.WhichOneof('layer')
    ins = list(layer.input); outs = list(layer.output)
    if kind == 'scale':
        rw = layer.scale.scale.float16Value
        W = (np.frombuffer(rw, np.float16).astype(np.float32) if len(rw) else np.array(layer.scale.scale.floatValue, np.float32)).reshape(-1, 1, 1)
        t[outs[0]] = t[ins[0]] * W
    elif kind == 'convolution':
        t[outs[0]] = conv(t[ins[0]], layer)
    elif kind == 'activation':
        k = layer.activation.WhichOneof('NonlinearityType')
        x = t[ins[0]]
        if k == 'ReLU': t[outs[0]] = np.maximum(x, 0)
        elif k == 'sigmoid': t[outs[0]] = 1 / (1 + np.exp(-x))
        elif k == 'linear': t[outs[0]] = layer.activation.linear.alpha * x + layer.activation.linear.beta
        else: raise RuntimeError('activation ' + str(k))
    elif kind == 'pooling':
        t[outs[0]] = pool_max(t[ins[0]], layer)
    elif kind == 'add':
        t[outs[0]] = sum(t[i] for i in ins)
    elif kind == 'concat':
        t[outs[0]] = np.concatenate([t[i] for i in ins], axis=0)
    elif kind == 'concatND':
        t[outs[0]] = np.concatenate([t[i] for i in ins], axis=0)
    elif kind == 'upsample':
        t[outs[0]] = upsample_bilinear(t[ins[0]], layer)
    else:
        raise RuntimeError('lớp chưa hỗ trợ trong bộ kiểm tra: ' + kind)

out = t['1959'][0]
err = np.abs(out - ref)
print('max abs err', float(err.max()), 'mean abs err', float(err.mean()), 'ref range', float(ref.min()), float(ref.max()))
