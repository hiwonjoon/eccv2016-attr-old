require 'residual-layers'
require 'nn'
require 'cifar-dataset'
require 'cutorch'
require 'cunn'
require 'cudnn'
require 'nngraph'
require 'train-helpers'
display = require 'display'
workbook = (require'lab-workbook-for-trello'):newExperiment{experimentName="CIFAR dev"}

opt = lapp[[
      --batchSize       (default 256)      Sub-batch size
      --iterSize        (default 1)       How many sub-batches in each batch
      --Nsize           (default 3)       Model has 6*n+2 layers.
      --dataRoot        (default /mnt/cifar) Data root folder
      --loadFrom        (default "")      Model to load
      --experimentName  (default "snapshots/cifar-residual-experiment1")
]]
print(opt)

-- create data loader
dataTrain = Dataset.CIFAR(opt.dataRoot, "train", opt.batchSize)
dataTest = Dataset.CIFAR(opt.dataRoot, "test", opt.batchSize)
local mean,std = dataTrain:preprocess()
dataTest:preprocess(mean,std)
print("Dataset size: ", dataTrain:size())


-- Residual network.
-- Input: 3x32x32
local N = opt.Nsize
if opt.loadFrom == "" then
    input = nn.Identity()()
    ------> 3, 32,32
    model = cudnn.SpatialConvolution(3, 16, 3,3, 1,1, 1,1)(input)
    model = cudnn.SpatialBatchNormalization(16)(model)
    model = cudnn.ReLU(true)(model)
    ------> 16, 32,32   First Group
    for i=1,N-1 do   model = addResidualLayer2(model, 16)   end
    model = addResidualLayer2(model, 16, 32, 2)
    ------> 32, 16,16   Second Group
    for i=1,N-1 do   model = addResidualLayer2(model, 32)   end
    model = addResidualLayer2(model, 32, 64, 2)
    ------> 64, 8,8     Third Group
    for i=1,N-1 do   model = addResidualLayer2(model, 64)   end
    model = addResidualLayer2(model, 64, 10, 1)
    ------> 10, 8,8     Pooling, Linear, Softmax
    model = nn.SpatialAveragePooling(8,8)(model)
    model = nn.Reshape(10)(model)
    model = nn.Linear(10, 10)(model)
    -- batch norm here? yes? no?
    model = nn.ReLU(true)(model)
    model = nn.LogSoftMax()(model)

    model = nn.gModule({input}, {model})
    model:cuda()
    --print(#model:forward(torch.randn(100, 3, 32,32):cuda()))
else
    print("Loading model from "..opt.loadFrom)
    cutorch.setDevice(1)
    model = torch.load(opt.loadFrom)
    print "Done"
end

loss = nn.ClassNLLCriterion()
loss:cuda()

-- Dirty trick: make the first conv layer weights easier to modify
-- model.modules[2].weight:mul(0.5)


sgdState = {
   --- For SGD with momentum ---
   ----[[
   -- My semi-working settings
   learningRate   = "will be set later",
   weightDecay    = 1e-4,
   -- Settings from their paper
   --learningRate = 0.1,
   --weightDecay    = 1e-4,

   momentum     = 0.9,
   dampening    = 0,
   nesterov     = true,
   --]]
   --- For rmsprop, which is very fiddly and I don't trust it at all ---
   --[[
   learningRate = 1e-5,
   alpha = 0.9,
   whichOptimMethod = 'rmsprop',
   --]]
   --- For adadelta, which sucks ---
   --[[
   rho              = 0.3,
   whichOptimMethod = 'adadelta',
   --]]
   --- For adagrad, which also sucks ---
   --[[
   learningRate = 3e-4,
   whichOptimMethod = 'adagrad',
   --]]
   --- For adam, which also sucks ---
   --[[
   learningRate = 0.005,
   whichOptimMethod = 'adam',
   --]]
   --- For the alternate implementation of NAG ---
   --[[
   learningRate = 0.01,
   weightDecay = 1e-6,
   momentum = 0.9,
   whichOptimMethod = 'nag',
   --]]
}


if opt.loadFrom ~= "" then
    print("Trying to load sgdState from "..string.gsub(opt.loadFrom, "model", "sgdState"))
    collectgarbage(); collectgarbage(); collectgarbage()
    sgdState = torch.load(""..string.gsub(opt.loadFrom, "model", "sgdState"))
    collectgarbage(); collectgarbage(); collectgarbage()
    print("Got", sgdState.nSampledImages,"images")
end

-- Actual Training! -----------------------------
weights, gradients = model:getParameters()
function forwardBackwardBatch(batch)
    -- After every batch, the different GPUs all have different gradients
    -- (because they saw different data), and only the first GPU's weights were
    -- actually updated.
    -- We have to do two changes:
    --   - Copy the new parameters from GPU #1 to the rest of them;
    --   - Zero the gradient parameters so we can accumulate them again.
    model:training()
    gradients:zero()

    -- From https://github.com/bgshih/cifar.torch/blob/master/train.lua#L119-L128
    if sgdState.epochCounter < 80 then
        sgdState.learningRate = 0.1
    elseif sgdState.epochCounter < 160 then
        sgdState.learningRate = 0.01
    else
        sgdState.learningRate = 0.001
    end

    local loss_val = 0
    local N = opt.iterSize
    local inputs, labels
    for i=1,N do
        inputs, labels = dataTrain:getBatch()
        inputs = inputs:cuda()
        labels = labels:cuda()
        collectgarbage(); collectgarbage();
        local y = model:forward(inputs)
        loss_val = loss_val + loss:forward(y, labels)
        local df_dw = loss:backward(y, labels)
        model:backward(inputs, df_dw)
        -- The above call will accumulate all GPUs' parameters onto GPU #1
    end
    loss_val = loss_val / N
    gradients:mul( 1.0 / N )

    if sgdState.nEvalCounter % 20 == 0 then
        display.image(model.modules[2].weight, {win=24, title="First layer weights"})
    end

    return loss_val, gradients, inputs:size(1) * N
end


function evalModel()
    -- if sgdState.epochCounter > 10 then os.exit(1) end
    local results = evaluateModel(model, dataTest)
    print(results)
    sgdState.accLog = sgdState.accLog or {}
    table.insert(sgdState.accLog, {sgdState.nSampledImages or 0, 1.0-results.correct1})
    workbook:plot("Test Classification Error", sgdState.accLog, {labels={'Images Seen', 'Error'},
                      title='Test Classification Error',
                      rollPeriod=1,
                      })
    --table.insert(sgdState.accuracies, acc)
    if (sgdState.epochCounter or 0) > 300 then
        print("Training complete, go home")
        os.exit()
    end
end

evalModel()

--[[
local results = evaluateModel(model, dataVal)
print(results)
--]]

--[[
require 'graph'
graph.dot(model.fg, 'MLP', '/tmp/MLP')
os.execute('convert /tmp/MLP.svg /tmp/MLP.png')
display.image(image.load('/tmp/MLP.png'), {title="Network Structure", win=23})
--]]

---[[
require 'ncdu-model-explore'
local y = model:forward(torch.randn(opt.batchSize, 3, 32,32):cuda())
local df_dw = loss:backward(y, torch.zeros(opt.batchSize):cuda())
model:backward(torch.randn(opt.batchSize,3,32,32):cuda(), df_dw)
exploreNcdu(model)
--]]


-- --[[
TrainingHelpers.trainForever(
model,
forwardBackwardBatch,
weights,
sgdState,
dataTrain:size(),
evalModel,
opt.experimentName,
10
)
--]]